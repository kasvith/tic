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
