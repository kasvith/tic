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
    /// Whether the note's panel was on screen when last seen — closing via the header X clears it,
    /// opening sets it — so launch restores only what was visible.
    var isOpen: Bool
    var sortIndex: Int

    // Per-note checklist display options (applied by `NoteController.displayedTasks`, not stored on
    // the tasks themselves): hide finished rows, and/or keep finished subtrees sunk to the bottom.
    var hideCompleted: Bool
    var moveCompletedToBottom: Bool
    /// Whether this list syncs with the user's other Macs (off until they choose it; lists that arrive
    /// from another Mac are synced). Per list, and itself synced: turning it off anywhere turns it off
    /// everywhere, and every Mac keeps its own copy.
    var isSynced: Bool

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
        isOpen: Bool = true,
        sortIndex: Int = 0,
        hideCompleted: Bool = false,
        moveCompletedToBottom: Bool = false,
        isSynced: Bool = false
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
        self.isOpen = isOpen
        self.sortIndex = sortIndex
        self.hideCompleted = hideCompleted
        self.moveCompletedToBottom = moveCompletedToBottom
        self.isSynced = isSynced
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let updatedAt = Column("updatedAt")
        static let sortIndex = Column("sortIndex")
        static let isOpen = Column("isOpen")
    }
}
// GRDB's default date storage is readable, sortable UTC text ("yyyy-MM-dd HH:mm:ss.SSS"),
// which is exactly what we want — no custom encoding strategy needed.
