import Foundation
import GRDB

/// A single checklist row belonging to a `Note`. Deleted automatically when its note is
/// deleted (FK `ON DELETE CASCADE`).
struct TaskItem: Identifiable, Equatable, Codable, Sendable {
    /// How deep a task is nested under the one(s) above it. `0` is a top-level task; the app
    /// caps this at `TaskItem.maxIndentLevel` (3 levels: 0, 1, 2). A task's *parent* is implicit
    /// — the nearest preceding task with a smaller level — so the flat, `sortIndex`-ordered list
    /// stays the single source of truth (no parent-id integrity to maintain across reorders).
    static let maxIndentLevel = 2

    var id: UUID
    var noteId: UUID
    var text: String
    var isDone: Bool
    var sortIndex: Int
    /// Nesting depth (0…`maxIndentLevel`). See ``TaskOutline`` for the rules that keep it valid.
    var indentLevel: Int
    var createdAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        noteId: UUID,
        text: String = "",
        isDone: Bool = false,
        sortIndex: Int = 0,
        indentLevel: Int = 0,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.noteId = noteId
        self.text = text
        self.isDone = isDone
        self.sortIndex = sortIndex
        self.indentLevel = indentLevel
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

extension TaskItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task"

    enum Columns {
        static let id = Column("id")
        static let noteId = Column("noteId")
        static let isDone = Column("isDone")
        static let sortIndex = Column("sortIndex")
    }
}
