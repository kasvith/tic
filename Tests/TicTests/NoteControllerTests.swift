import Foundation
import Testing
@testable import Tic

/// The rapid-add *data* flow, driven through `NoteController` exactly as `NoteView` drives it:
/// `addSubtask` to open the first row, then `addSibling` + `commitText` to chain the rest.
///
/// We assert against the controller's optimistic `tasks`, which the add/commit methods mutate
/// synchronously — so these are deterministic and need no running observation. The in-memory DB has
/// the note inserted first so the fire-and-forget writes don't trip the task→note foreign key.
@MainActor
@Suite("NoteController rapid-add")
struct NoteControllerTests {
    private func makeController() async throws -> NoteController {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        return NoteController(note: note, database: db)
    }

    @Test("rapid-add keeps new subtasks at the same level, in entry order, below existing children")
    func rapidAddSameLevel() async throws {
        let c = try await makeController()
        c.addTask("Heading")                 // [Heading L0]
        c.addTask("Existing", level: 1)      // [Heading L0, Existing L1]
        let heading = try #require(c.tasks.first)

        // Open the run: an empty row at the bottom of the heading's group, one level deeper.
        let id1 = try #require(c.addSubtask(under: heading))
        c.commitText(try #require(c.tasks.first { $0.id == id1 }), "A")

        // Continue: a sibling just below the row committed before it, at the same level.
        let a = try #require(c.tasks.first { $0.id == id1 })
        let id2 = try #require(c.addSibling(below: a))
        c.commitText(try #require(c.tasks.first { $0.id == id2 }), "B")

        #expect(c.tasks.map(\.text) == ["Heading", "Existing", "A", "B"])
        #expect(c.tasks.map(\.indentLevel) == [0, 1, 1, 1])   // never dives deeper
    }

    @Test("committing an empty row removes it, and addSibling on it returns nil (ends the run)")
    func emptyEndsRun() async throws {
        let c = try await makeController()
        c.addTask("Heading")
        let heading = try #require(c.tasks.first)
        let id1 = try #require(c.addSubtask(under: heading))
        let row = try #require(c.tasks.first { $0.id == id1 })

        c.commitText(row, "   ")             // whitespace-only → discarded
        #expect(c.tasks.first { $0.id == id1 } == nil)
        #expect(c.addSibling(below: row) == nil)   // gone → run ends, no phantom row
        #expect(c.tasks.map(\.text) == ["Heading"])
    }

    @Test("a sibling inherits the committed row's current level after a mid-run indent")
    func siblingInheritsIndentedLevel() async throws {
        let c = try await makeController()
        c.addTask("Heading")
        let heading = try #require(c.tasks.first)

        let x = try #require(c.addSubtask(under: heading))           // X at L1
        c.commitText(try #require(c.tasks.first { $0.id == x }), "X")
        let xRow = try #require(c.tasks.first { $0.id == x })

        let y = try #require(c.addSibling(below: xRow))             // Y at L1
        c.indent(try #require(c.tasks.first { $0.id == y }))        // Y → L2 (nested under X)
        let yRow = try #require(c.tasks.first { $0.id == y })
        #expect(yRow.indentLevel == 2)

        let z = try #require(c.addSibling(below: yRow))             // Z inherits Y's live level
        #expect(c.tasks.first { $0.id == z }?.indentLevel == 2)
    }

    @Test("committing a subtask leaves every other row's tick state untouched")
    func commitPreservesOtherTicks() async throws {
        let c = try await makeController()
        c.addTask("Heading")
        c.addTask("Done", level: 1)
        let done = try #require(c.tasks.first { $0.text == "Done" })
        c.toggle(done)                                              // mark "Done" complete
        #expect(c.tasks.first { $0.text == "Done" }?.isDone == true)

        let heading = try #require(c.tasks.first)
        let id1 = try #require(c.addSubtask(under: heading))
        c.commitText(try #require(c.tasks.first { $0.id == id1 }), "New")

        #expect(c.tasks.first { $0.text == "Done" }?.isDone == true)   // tick survives the add
        #expect(c.tasks.first { $0.text == "New" }?.isDone == false)
    }
}

/// The completed-display options (hide / move-to-bottom / clear), driven through the controller's
/// optimistic `tasks` and `note` exactly as `NoteView`/`NoteHeaderView` drive them.
@MainActor
@Suite("NoteController completed options")
struct NoteControllerCompletedOptionsTests {
    private func makeController() async throws -> NoteController {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        return NoteController(note: note, database: db)
    }

    /// Builds `[A, B, C]` at level 0 with B marked done.
    private func threeWithMiddleDone(_ c: NoteController) throws {
        c.addTask("A")
        c.addTask("B")
        c.addTask("C")
        c.toggle(try #require(c.tasks.first { $0.text == "B" }))
    }

    @Test("displayedTasks reflects each option and both together; equals tasks when both are off")
    func displayedTasksReflectsFlags() async throws {
        let c = try await makeController()
        try threeWithMiddleDone(c)

        #expect(c.displayedTasks.map(\.text) == ["A", "B", "C"])   // both off → identity

        c.toggleHideCompleted()
        #expect(c.displayedTasks.map(\.text) == ["A", "C"])        // done B hidden

        c.toggleHideCompleted()                                    // back on-screen
        c.toggleMoveCompletedToBottom()
        #expect(c.displayedTasks.map(\.text) == ["A", "C", "B"])   // done B sinks

        c.toggleHideCompleted()                                    // both on → hide dominates
        #expect(c.displayedTasks.map(\.text) == ["A", "C"])
    }

    @Test("isReorderable follows move-to-bottom only; hiding leaves it reorderable")
    func isReorderableFollowsMove() async throws {
        let c = try await makeController()
        #expect(c.isReorderable)                 // default
        c.toggleHideCompleted()
        #expect(c.isReorderable)                 // hiding still allows reorder (remap)
        c.toggleMoveCompletedToBottom()
        #expect(!c.isReorderable)                // auto-sort pauses reorder
        c.toggleMoveCompletedToBottom()
        #expect(c.isReorderable)
    }

    @Test("trueInsertionIndex is the identity by default and remaps around hidden rows")
    func trueInsertionIndexRemap() async throws {
        let c = try await makeController()
        try threeWithMiddleDone(c)               // tasks: A(nd) B(done) C(nd)

        // Identity while nothing is transformed.
        #expect(c.trueInsertionIndex(forDisplayedIndex: 0) == 0)
        #expect(c.trueInsertionIndex(forDisplayedIndex: 2) == 2)

        c.toggleHideCompleted()                  // displayed: [A, C]
        #expect(c.trueInsertionIndex(forDisplayedIndex: 0) == 0)   // before A
        #expect(c.trueInsertionIndex(forDisplayedIndex: 1) == 2)   // before C (skips hidden B)
        #expect(c.trueInsertionIndex(forDisplayedIndex: 2) == 3)   // end → after last visible subtree
    }

    @Test("completedCount tracks done tasks regardless of display options")
    func completedCountTracksDone() async throws {
        let c = try await makeController()
        #expect(c.completedCount == 0)
        try threeWithMiddleDone(c)
        #expect(c.completedCount == 1)
        c.toggleHideCompleted()                  // hiding doesn't change the count
        #expect(c.completedCount == 1)
    }

    @Test("clearCompleted removes done rows, keeps survivor order/levels/ticks, and renumbers")
    func clearCompletedRemovesDone() async throws {
        let c = try await makeController()
        c.addTask("P")
        c.addTask("c1", level: 1)
        c.addTask("c2", level: 1)
        c.toggle(try #require(c.tasks.first { $0.text == "c1" }))   // c1 done; P stays open (c2 open)
        #expect(c.completedCount == 1)

        c.clearCompleted()
        #expect(c.tasks.map(\.text) == ["P", "c2"])                // done c1 gone, order preserved
        #expect(c.tasks.map(\.indentLevel) == [0, 1])              // survivor levels renormalised
        #expect(c.tasks.allSatisfy { !$0.isDone })
        // The contiguous sortIndex renumber is a DB concern (fire-and-forget here) and is verified in
        // AppDatabaseTests.batchDelete; the optimistic array keeps the survivors' original indices.
    }

    @Test("clearCompleted is a no-op when nothing is completed")
    func clearCompletedNoop() async throws {
        let c = try await makeController()
        c.addTask("A")
        c.addTask("B")
        c.clearCompleted()
        #expect(c.tasks.map(\.text) == ["A", "B"])
    }

    @Test("the two toggles flip their note flags independently")
    func togglesFlipFlags() async throws {
        let c = try await makeController()
        #expect(!c.note.hideCompleted)
        #expect(!c.note.moveCompletedToBottom)

        c.toggleHideCompleted()
        #expect(c.note.hideCompleted)
        #expect(!c.note.moveCompletedToBottom)

        c.toggleMoveCompletedToBottom()
        #expect(c.note.hideCompleted)
        #expect(c.note.moveCompletedToBottom)
    }
}
