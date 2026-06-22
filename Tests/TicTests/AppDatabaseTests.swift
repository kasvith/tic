import Foundation
import Testing
@testable import Tic

@Suite("AppDatabase")
struct AppDatabaseTests {
    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }

    @Test("seed creates the welcome note with its tasks")
    func seed() async throws {
        let db = try makeDB()
        try db.seedSampleDataIfEmpty()

        let notes = try await db.allNotes()
        #expect(notes.count == 1)
        let today = try #require(notes.first)
        #expect(today.title == "Today")

        let tasks = try await db.tasks(noteId: today.id)
        #expect(tasks.count == 4)
        #expect(tasks.map(\.sortIndex) == [0, 1, 2, 3])
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

    @Test("reorderTasks writes only sortIndex and preserves other fields")
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
        try await db.reorderTasks([tasks[2], tasks[0], tasks[1]])

        let after = try await db.tasks(noteId: note.id)
        #expect(after.map(\.text) == ["t2", "t0", "t1"])
        #expect(after.map(\.sortIndex) == [0, 1, 2])
        #expect(after.first { $0.text == "t0" }?.isDone == true)
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
