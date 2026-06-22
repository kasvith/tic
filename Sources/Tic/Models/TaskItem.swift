import Foundation
import GRDB

/// A single checklist row belonging to a `Note`. Deleted automatically when its note is
/// deleted (FK `ON DELETE CASCADE`).
struct TaskItem: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var noteId: UUID
    var text: String
    var isDone: Bool
    var sortIndex: Int
    var createdAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        noteId: UUID,
        text: String = "",
        isDone: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.noteId = noteId
        self.text = text
        self.isDone = isDone
        self.sortIndex = sortIndex
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
