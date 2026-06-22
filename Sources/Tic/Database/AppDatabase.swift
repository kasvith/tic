import Foundation
import GRDB

/// Owns the SQLite connection (via GRDB) and exposes typed CRUD operations plus live
/// `ValueObservation` streams that SwiftUI subscribes to. Thread-safe: GRDB's `DatabaseQueue`
/// serialises all access.
final class AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    // MARK: - Setup

    /// The shared on-disk database at `~/Library/Application Support/Tic/tic.sqlite`.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport.appendingPathComponent("Tic", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tic.sqlite")

        let db = try AppDatabase(try DatabaseQueue(path: dbURL.path))
        try db.seedSampleDataIfEmpty()
        return db
    }

    /// An ephemeral in-memory database, for previews and tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    var path: String { dbQueue.path }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // During development, wipe and rebuild when the schema changes instead of crashing.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_notes_and_tasks") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("color", .text).notNull()
                t.column("material", .text).notNull()
                t.column("frameX", .double).notNull()
                t.column("frameY", .double).notNull()
                t.column("frameW", .double).notNull()
                t.column("frameH", .double).notNull()
                t.column("floatOnTop", .boolean).notNull().defaults(to: false)
                t.column("showOnAllSpaces", .boolean).notNull().defaults(to: false)
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("noteId", .blob).notNull()
                    .references("note", onDelete: .cascade)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(index: "task_on_noteId", on: "task", columns: ["noteId"])
        }

        return migrator
    }

    // MARK: - Notes

    func allNotes() async throws -> [Note] {
        try await dbQueue.read { db in
            try Note.order(Note.Columns.sortIndex).fetchAll(db)
        }
    }

    func insert(_ note: Note) async throws {
        try await dbQueue.write { db in try note.insert(db) }
    }

    /// Updates a note, stamping `updatedAt`.
    func update(_ note: Note) async throws {
        var updated = note
        updated.updatedAt = Date()
        let snapshot = updated
        try await dbQueue.write { db in try snapshot.update(db) }
    }

    func deleteNote(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try Note.filter(Note.Columns.id == id).deleteAll(db)
        }
    }

    /// Targeted write of just a note's window frame, so frequent drag/resize saves never race
    /// with edits to other fields (title, tasks, flags).
    func updateNoteFrame(id: UUID, x: Double, y: Double, width: Double, height: Double) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET frameX = ?, frameY = ?, frameW = ?, frameH = ?, updatedAt = ? WHERE id = ?",
                arguments: [x, y, width, height, Date(), id]
            )
        }
    }

    /// Targeted write of a note's title.
    func updateNoteTitle(id: UUID, title: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title, Date(), id]
            )
        }
    }

    /// Targeted write of a note's appearance (colour + material).
    func updateNoteAppearance(id: UUID, color: NoteColor, material: NoteMaterial) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET color = ?, material = ?, updatedAt = ? WHERE id = ?",
                arguments: [color.rawValue, material.rawValue, Date(), id]
            )
        }
    }

    /// Targeted write of a note's window behaviour flags.
    func updateNoteFlags(id: UUID, floatOnTop: Bool, showOnAllSpaces: Bool, isCollapsed: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET floatOnTop = ?, showOnAllSpaces = ?, isCollapsed = ?, updatedAt = ? WHERE id = ?",
                arguments: [floatOnTop, showOnAllSpaces, isCollapsed, Date(), id]
            )
        }
    }

    /// Emits the full ordered list of notes whenever any note changes.
    func observeNotes() -> AsyncValueObservation<[Note]> {
        ValueObservation
            .tracking { db in try Note.order(Note.Columns.sortIndex).fetchAll(db) }
            .values(in: dbQueue)
    }

    // MARK: - Tasks

    func tasks(noteId: UUID) async throws -> [TaskItem] {
        try await dbQueue.read { db in
            try TaskItem
                .filter(TaskItem.Columns.noteId == noteId)
                .order(TaskItem.Columns.sortIndex)
                .fetchAll(db)
        }
    }

    func insert(_ task: TaskItem) async throws {
        try await dbQueue.write { db in try task.insert(db) }
    }

    func update(_ task: TaskItem) async throws {
        try await dbQueue.write { db in try task.update(db) }
    }

    func deleteTask(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try TaskItem.filter(TaskItem.Columns.id == id).deleteAll(db)
        }
    }

    /// Persists a new ordering for a note's tasks (called after a drag-to-reorder).
    /// Writes ONLY the `sortIndex` column so a reorder (which runs off a possibly-stale snapshot
    /// during a live drag) can never clobber a concurrently-edited `text`/`isDone`.
    func reorderTasks(_ ordered: [TaskItem]) async throws {
        try await dbQueue.write { db in
            for (index, task) in ordered.enumerated() where task.sortIndex != index {
                try db.execute(
                    sql: "UPDATE task SET sortIndex = ? WHERE id = ?",
                    arguments: [index, task.id]
                )
            }
        }
    }

    /// Emits a note's ordered tasks whenever any of them change.
    func observeTasks(noteId: UUID) -> AsyncValueObservation<[TaskItem]> {
        ValueObservation
            .tracking { db in
                try TaskItem
                    .filter(TaskItem.Columns.noteId == noteId)
                    .order(TaskItem.Columns.sortIndex)
                    .fetchAll(db)
            }
            .values(in: dbQueue)
    }

    // MARK: - Seeding

    /// On a brand-new database, drops in a friendly welcome note so there's something on screen.
    func seedSampleDataIfEmpty() throws {
        try dbQueue.write { db in
            guard try Note.fetchCount(db) == 0 else { return }
            let now = Date()
            let note = Note(
                title: "Today",
                color: .yellow,
                material: .solid,
                frameX: 140, frameY: 220, frameW: 290, frameH: 380,
                sortIndex: 0
            )
            try note.insert(db)

            let samples = [
                "Welcome to Tic 👋",
                "Tap the circle to finish a task",
                "Press Return to add another",
                "Drag anywhere to move the note"
            ]
            for (index, text) in samples.enumerated() {
                let task = TaskItem(noteId: note.id, text: text, sortIndex: index, createdAt: now)
                try task.insert(db)
            }
        }
    }
}
