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

        migrator.registerMigration("v2_task_indent_level") { db in
            try db.alter(table: "task") { t in
                t.add(column: "indentLevel", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v3_note_completed_options") { db in
            try db.alter(table: "note") { t in
                t.add(column: "hideCompleted", .boolean).notNull().defaults(to: false)
                t.add(column: "moveCompletedToBottom", .boolean).notNull().defaults(to: false)
            }
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

    /// Inserts a note assigning the next `sortIndex` (`MAX + 1`) atomically inside the write, so
    /// concurrent/rapid creation can't collide and ordering stays stable regardless of which
    /// notes happen to be open. Returns the stored note (with its assigned `sortIndex`).
    @discardableResult
    func insertNewNote(_ note: Note) async throws -> Note {
        try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM note") ?? -1
            var stored = note
            stored.sortIndex = maxIndex + 1
            if stored.title.isEmpty {
                // Default name based on how many lists exist *now*: 0 lists → "List 1"; after you
                // rename one and add another you get "List 2" (not "List 1" again); restarting with
                // zero lists naturally starts back at 1. Bump past any clash so names stay unique.
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
                let titles = try String.fetchSet(db, sql: "SELECT title FROM note")
                var n = count + 1
                while titles.contains("List \(n)") { n += 1 }
                stored.title = "List \(n)"
            }
            try stored.insert(db)
            return stored
        }
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

    /// Targeted write of a note's checklist display options (hide completed / move completed to
    /// bottom). Kept separate from `updateNoteFlags` (window behaviour) so each stays column-targeted.
    func updateNoteListOptions(id: UUID, hideCompleted: Bool, moveCompletedToBottom: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET hideCompleted = ?, moveCompletedToBottom = ?, updatedAt = ? WHERE id = ?",
                arguments: [hideCompleted, moveCompletedToBottom, Date(), id]
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

    /// Inserts a task assigning the next `sortIndex` (`MAX + 1` for the note) atomically inside the
    /// write, so a `tasks.count`-based index can't collide with a stale row after deletes leave gaps.
    func insertTask(_ task: TaskItem) async throws {
        let snapshot = task
        try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(
                db, sql: "SELECT MAX(sortIndex) FROM task WHERE noteId = ?", arguments: [snapshot.noteId]
            ) ?? -1
            var stored = snapshot
            stored.sortIndex = maxIndex + 1
            try stored.insert(db)
        }
    }

    /// Inserts `task` somewhere in the middle of a note's list (e.g. a subtask nested under a row),
    /// then renumbers every row's `sortIndex` to its position in `ordered` — all in one transaction
    /// so the observation sees a single consistent ordering. `ordered` is the full intended list
    /// *including* the new task.
    func insertTask(_ task: TaskItem, reordering ordered: [TaskItem]) async throws {
        let snapshot = task
        let order = ordered
        try await dbQueue.write { db in
            try snapshot.insert(db)
            for (index, t) in order.enumerated() {
                try db.execute(sql: "UPDATE task SET sortIndex = ? WHERE id = ?", arguments: [index, t.id])
            }
        }
    }

    func update(_ task: TaskItem) async throws {
        try await dbQueue.write { db in try task.update(db) }
    }

    /// One atomic transaction for a structural edit (indent / outdent / delete / drag-reorder /
    /// clear-completed), so the live observation never sees a transient invalid outline. Touches only
    /// the structural columns (`sortIndex`, `indentLevel`) plus optional row deletes — never `text` or
    /// the completion columns, so a structural change can neither clobber a concurrently-edited task
    /// body nor alter any tick state (completion only ever changes via `updateTaskCompletion`).
    /// `deleteIds` may hold one row (single delete) or many (clear-completed), removed in one `IN (…)`.
    func applyStructuralUpdate(
        deleteIds: [UUID] = [],
        reorder ordered: [TaskItem]? = nil,
        levels: [TaskLevelUpdate] = []
    ) async throws {
        try await dbQueue.write { db in
            if !deleteIds.isEmpty {
                _ = try TaskItem.filter(deleteIds.contains(TaskItem.Columns.id)).deleteAll(db)
            }
            if let ordered {
                for (index, task) in ordered.enumerated() where task.sortIndex != index {
                    try db.execute(sql: "UPDATE task SET sortIndex = ? WHERE id = ?", arguments: [index, task.id])
                }
            }
            for u in levels {
                try db.execute(sql: "UPDATE task SET indentLevel = ? WHERE id = ?", arguments: [u.level, u.id])
            }
        }
    }

    /// Targeted write of the `isDone` + `completedAt` columns for the given tasks (a checkbox
    /// toggle, which cascades through a subtree and bubbles up to ancestors). Writes only the
    /// completion columns so it never clobbers a concurrently-edited `text` or a reorder.
    func updateTaskCompletion(_ updates: [TaskCompletionUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await dbQueue.write { db in
            try Self.writeCompletion(updates, db)
        }
    }

    /// Writes `isDone` + `completedAt` for each update, inside an existing write transaction.
    private static func writeCompletion(_ updates: [TaskCompletionUpdate], _ db: Database) throws {
        for u in updates {
            try db.execute(
                sql: "UPDATE task SET isDone = ?, completedAt = ? WHERE id = ?",
                arguments: [u.isDone, u.completedAt, u.id]
            )
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

}

/// One sample row for the welcome notes — a named type instead of a 3-tuple.
private struct SeedTask {
    let text: String
    let level: Int
    let done: Bool
    init(_ text: String, _ level: Int, _ done: Bool) {
        self.text = text
        self.level = level
        self.done = done
    }
}

// MARK: - Seeding

extension AppDatabase {
    /// On a brand-new database, drops in a couple of welcome notes that double as a feature tour —
    /// one showing subtasks / Markdown / multiline / completion, and a second listing the keyboard
    /// shortcuts so they're discoverable.
    func seedSampleDataIfEmpty() throws {
        try dbQueue.write { db in
            guard try Note.fetchCount(db) == 0 else { return }
            let now = Date()

            func seed(_ note: Note, _ items: [SeedTask]) throws {
                try note.insert(db)
                for (index, item) in items.enumerated() {
                    let task = TaskItem(
                        noteId: note.id, text: item.text, isDone: item.done,
                        sortIndex: index, indentLevel: item.level,
                        createdAt: now, completedAt: item.done ? now : nil
                    )
                    try task.insert(db)
                }
            }

            try seed(
                Note(
                    title: "Welcome to Tic 👋", color: .yellow, material: .solid,
                    frameX: 130, frameY: 200, frameW: 300, frameH: 440, sortIndex: 0
                ),
                [
                    SeedTask("Tap the circle to finish a task", 0, false),
                    SeedTask("Break big tasks into subtasks", 0, false),
                    SeedTask("Hover a row and click the + below it", 1, false),
                    SeedTask("…or press Shift-Tab while editing", 1, false),
                    SeedTask("*Markdown* — **bold**, `code`, ~~strike~~, [links](https://kasvith.me)", 0, false),
                    SeedTask("Need detail? Press Shift-Return\nfor a new line in the same task", 0, false),
                    SeedTask("Completing a parent completes its subtasks", 0, true),
                    SeedTask("buy milk", 1, true),
                    SeedTask("water the plants", 1, true),
                    SeedTask("⭐️ Star Tic on [GitHub](https://github.com/kasvith/tic)", 0, false),
                ]
            )

            try seed(
                Note(
                    title: "Shortcuts ⌨️", color: .blue, material: .solid,
                    frameX: 470, frameY: 260, frameW: 300, frameH: 320, sortIndex: 1
                ),
                [
                    SeedTask("**Return** — finish editing, or add a task", 0, false),
                    SeedTask("**Shift-Return** — new line in the same task", 0, false),
                    SeedTask("**Shift-Tab** — make it a subtask", 0, false),
                    SeedTask("**Ctrl-Shift-Tab** — move it back out", 0, false),
                    SeedTask("**Drag** to reorder — or drag right to nest", 0, false),
                    SeedTask("**Double-click** the header to roll up", 0, false),
                ]
            )
        }
    }
}

/// A targeted `indentLevel` change for one task — batched into `applyStructuralUpdate`.
struct TaskLevelUpdate: Sendable {
    let id: UUID
    let level: Int
}

/// A targeted completion change for one task — batched by `updateTaskCompletion`.
struct TaskCompletionUpdate: Sendable {
    let id: UUID
    let isDone: Bool
    let completedAt: Date?
}
