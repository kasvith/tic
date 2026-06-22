import Foundation
import GRDB

/// A sticky note: a titled, coloured, positioned container for a checklist of `TaskItem`s.
///
/// Sync-friendly by design — stable `UUID` id and an `updatedAt` timestamp leave room for
/// last-write-wins reconciliation if iCloud sync is added later.
struct Note: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var color: NoteColor
    var material: NoteMaterial

    // Window placement (screen coordinates), persisted so panels restore where you left them.
    var frameX: Double
    var frameY: Double
    var frameW: Double
    var frameH: Double

    var floatOnTop: Bool
    var showOnAllSpaces: Bool
    var isCollapsed: Bool
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        color: NoteColor = .yellow,
        material: NoteMaterial = .solid,
        frameX: Double = 160,
        frameY: Double = 240,
        frameW: Double = 280,
        frameH: Double = 360,
        floatOnTop: Bool = false,
        showOnAllSpaces: Bool = false,
        isCollapsed: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.color = color
        self.material = material
        self.frameX = frameX
        self.frameY = frameY
        self.frameW = frameW
        self.frameH = frameH
        self.floatOnTop = floatOnTop
        self.showOnAllSpaces = showOnAllSpaces
        self.isCollapsed = isCollapsed
        self.sortIndex = sortIndex
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let updatedAt = Column("updatedAt")
        static let sortIndex = Column("sortIndex")
    }
}
// GRDB's default date storage is readable, sortable UTC text ("yyyy-MM-dd HH:mm:ss.SSS"),
// which is exactly what we want — no custom encoding strategy needed.
