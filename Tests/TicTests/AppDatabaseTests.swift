import Foundation
import Testing
@testable import Tic

@Suite("AppDatabase")
struct AppDatabaseTests {
    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }

    @Test("seed creates the welcome + shortcuts notes, showcasing subtasks and completion")
    func seed() async throws {
        let db = try makeDB()
        try db.seedSampleDataIfEmpty()

        let notes = try await db.allNotes()
        #expect(notes.count == 2)
        #expect(notes.map(\.title) == ["Welcome to Tic 👋", "Shortcuts ⌨️"])

        let welcome = try #require(notes.first)
        let tasks = try await db.tasks(noteId: welcome.id)
        #expect(tasks.map(\.sortIndex) == Array(0..<tasks.count))
        #expect(tasks.contains { $0.indentLevel == 1 })            // demonstrates subtasks
        #expect(tasks.contains { $0.isDone && $0.completedAt != nil }) // a finished example
    }

    @Test("seed is idempotent — it never duplicates the welcome notes")
    func seedIdempotent() async throws {
        let db = try makeDB()
        try db.seedSampleDataIfEmpty()
        try db.seedSampleDataIfEmpty()
        #expect(try await db.allNotes().count == 2)
    }

    @Test("new lists are auto-named List 1, List 2, …")
    func autoNaming() async throws {
        let db = try makeDB()
        let first = try await db.insertNewNote(Note())
        let second = try await db.insertNewNote(Note())
        #expect(first.title == "List 1")
        #expect(second.title == "List 2")
    }

    @Test("renaming a list still counts the next one up (not reusing the freed name)")
    func autoNamingAfterRename() async throws {
        let db = try makeDB()
        var first = try await db.insertNewNote(Note())   // List 1
        first.title = "Groceries"
        try await db.update(first)

        let next = try await db.insertNewNote(Note())     // 1 list exists → List 2
        #expect(next.title == "List 2")
    }

    @Test("auto-name bumps past an existing clash")
    func autoNamingClash() async throws {
        let db = try makeDB()
        let one = try await db.insertNewNote(Note())   // List 1
        _ = try await db.insertNewNote(Note())          // List 2
        try await db.deleteNote(id: one.id)             // now only "List 2" remains
        let next = try await db.insertNewNote(Note())   // count 1 → "List 2" clashes → "List 3"
        #expect(next.title == "List 3")
    }

    @Test("insertNewNote assigns an increasing sortIndex")
    func sortIndexIncrements() async throws {
        let db = try makeDB()
        let a = try await db.insertNewNote(Note())
        let b = try await db.insertNewNote(Note())
        #expect(b.sortIndex == a.sortIndex + 1)
    }

    @Test("applyStructuralUpdate reorder writes only sortIndex and preserves other fields")
    func reorder() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        for i in 0..<3 {
            try await db.insert(TaskItem(noteId: note.id, text: "t\(i)", sortIndex: i))
        }

        var tasks = try await db.tasks(noteId: note.id)
        tasks[0].isDone = true                 // t0 done — must survive a reorder
        try await db.update(tasks[0])

        tasks = try await db.tasks(noteId: note.id)
        try await db.applyStructuralUpdate(reorder: [tasks[2], tasks[0], tasks[1]])

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["t2", "t0", "t1"])
        #expect(after.map(\.sortIndex) == [0, 1, 2])
        #expect(after.first { $0.text == "t0" }?.isDone == true)
    }

    @Test("indentLevel round-trips through insert and fetch")
    func indentLevelRoundTrips() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "child", sortIndex: 0, indentLevel: 2))

        let fetched = try #require(try await db.tasks(noteId: note.id).first)
        #expect(fetched.indentLevel == 2)
    }

    @Test("applyStructuralUpdate levels write only indentLevel, preserving text and isDone")
    func targetedIndentUpdate() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "a", isDone: true, sortIndex: 0))

        let task = try #require(try await db.tasks(noteId: note.id).first)
        try await db.applyStructuralUpdate(levels: [TaskLevelUpdate(id: task.id, level: 1)])

        let after = try #require(try await db.tasks(noteId: note.id).first)
        #expect(after.indentLevel == 1)
        #expect(after.text == "a")
        #expect(after.isDone)
    }

    @Test("applyStructuralUpdate applies delete + level changes atomically, leaving ticks untouched")
    func structuralUpdateAtomic() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "p", isDone: true, sortIndex: 0, indentLevel: 0))
        try await db.insert(TaskItem(noteId: note.id, text: "c", sortIndex: 1, indentLevel: 1))
        try await db.insert(TaskItem(noteId: note.id, text: "gone", sortIndex: 2, indentLevel: 1))

        let tasks = try await db.tasks(noteId: note.id)
        let child = try #require(tasks.first { $0.text == "c" })
        let doomed = try #require(tasks.first { $0.text == "gone" })

        // Delete one row and promote the child to level 0 — in one write. Ticks must not change.
        try await db.applyStructuralUpdate(
            deleteId: doomed.id,
            levels: [TaskLevelUpdate(id: child.id, level: 0)]
        )

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["p", "c"])
        #expect(after.first { $0.text == "c" }?.indentLevel == 0)
        #expect(after.first { $0.text == "p" }?.isDone == true)   // tick preserved
    }

    @Test("insertTask assigns MAX+1 sortIndex, avoiding collisions after a delete leaves a gap")
    func insertTaskNoCollision() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        for i in 0..<3 {
            try await db.insert(TaskItem(noteId: note.id, text: "t\(i)", sortIndex: i))
        }
        // Delete the middle row → surviving sortIndexes are [0, 2], a gap at 1.
        let middle = try #require(try await db.tasks(noteId: note.id).first { $0.text == "t1" })
        try await db.applyStructuralUpdate(deleteId: middle.id)

        try await db.insertTask(TaskItem(noteId: note.id, text: "new"))

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["t0", "t2", "new"])           // ordered, new is last
        #expect(Set(after.map(\.sortIndex)).count == after.count)    // all sortIndexes unique
        #expect(after.last?.sortIndex == 3)                          // MAX(2) + 1
    }

    @Test("insertTask(reordering:) inserts mid-list, renumbers sortIndex, and preserves other rows")
    func insertTaskReordering() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        // A parent with two children; one child is already done — its tick must survive the insert.
        try await db.insert(TaskItem(noteId: note.id, text: "P", sortIndex: 0, indentLevel: 0))
        try await db.insert(TaskItem(noteId: note.id, text: "C1", isDone: true, sortIndex: 1, indentLevel: 1))
        try await db.insert(TaskItem(noteId: note.id, text: "C2", sortIndex: 2, indentLevel: 1))

        // Insert a new subtask at the bottom of P's subtree (index 3), one level deep.
        let tasks = try await db.tasks(noteId: note.id)
        let newTask = TaskItem(noteId: note.id, text: "S1", indentLevel: 1)
        var ordered = tasks
        ordered.append(newTask)
        try await db.insertTask(newTask, reordering: ordered)

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["P", "C1", "C2", "S1"])
        #expect(after.map(\.sortIndex) == [0, 1, 2, 3])             // contiguous after renumber
        #expect(after.first { $0.text == "C1" }?.isDone == true)    // tick untouched
        #expect(after.first { $0.text == "C1" }?.indentLevel == 1)  // level untouched
        #expect(after.first { $0.text == "S1" }?.indentLevel == 1)
    }

    @Test("rapid-add inserts siblings below in entry order without disturbing existing rows")
    func insertSiblingsBuildDownward() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "P", sortIndex: 0, indentLevel: 0))
        try await db.insert(TaskItem(noteId: note.id, text: "C", isDone: true, sortIndex: 1, indentLevel: 1))

        // First subtask under P → bottom of P's subtree.
        var tasks = try await db.tasks(noteId: note.id)
        let firstIdx = TaskOutline.subtreeRange(tasks, at: 0).upperBound
        let s1 = TaskItem(noteId: note.id, text: "S1", indentLevel: 1)
        var ordered = tasks
        ordered.insert(s1, at: firstIdx)
        try await db.insertTask(s1, reordering: ordered)

        // Continuation: a sibling just below S1, at the same level.
        tasks = try await db.tasks(noteId: note.id)
        let s1Index = try #require(tasks.firstIndex { $0.text == "S1" })
        let spot = try #require(TaskOutline.siblingInsertion(tasks, after: s1Index))
        let s2 = TaskItem(noteId: note.id, text: "S2", indentLevel: spot.level)
        ordered = tasks
        ordered.insert(s2, at: spot.index)
        try await db.insertTask(s2, reordering: ordered)

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["P", "C", "S1", "S2"])       // entry order, below existing child
        #expect(after.map(\.sortIndex) == [0, 1, 2, 3])
        #expect(after.first { $0.text == "C" }?.isDone == true)    // existing tick untouched
        #expect(spot.level == 1)                                    // sibling stays at the child's level
    }

    @Test("updateTaskCompletion writes only completion columns, preserving text and indentLevel")
    func targetedCompletionUpdate() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "a", sortIndex: 0, indentLevel: 1))

        let task = try #require(try await db.tasks(noteId: note.id).first)
        let stamp = Date(timeIntervalSince1970: 5_000)
        try await db.updateTaskCompletion([
            TaskCompletionUpdate(id: task.id, isDone: true, completedAt: stamp)
        ])

        let after = try #require(try await db.tasks(noteId: note.id).first)
        #expect(after.isDone)
        #expect(after.completedAt == stamp)
        #expect(after.text == "a")
        #expect(after.indentLevel == 1)
    }

    @Test("deleting a note cascades to its tasks")
    func cascadeDelete() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.insert(TaskItem(noteId: note.id, text: "x"))

        try await db.deleteNote(id: note.id)
        #expect(try await db.allNotes().isEmpty)
        #expect(try await db.tasks(noteId: note.id).isEmpty)
    }

    @Test("targeted title update leaves other fields untouched")
    func targetedTitleUpdate() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note(color: .blue))
        try await db.updateNoteTitle(id: note.id, title: "Renamed")

        let fetched = try #require(try await db.allNotes().first)
        #expect(fetched.title == "Renamed")
        #expect(fetched.color == .blue)
    }

    @Test("targeted appearance + flags updates round-trip")
    func targetedAppearanceAndFlags() async throws {
        let db = try makeDB()
        let note = try await db.insertNewNote(Note())
        try await db.updateNoteAppearance(id: note.id, color: .green, material: .glass)
        try await db.updateNoteFlags(id: note.id, floatOnTop: true, showOnAllSpaces: true, isCollapsed: true)

        let fetched = try #require(try await db.allNotes().first)
        #expect(fetched.color == .green)
        #expect(fetched.material == .glass)
        #expect(fetched.floatOnTop)
        #expect(fetched.showOnAllSpaces)
        #expect(fetched.isCollapsed)
    }
}
