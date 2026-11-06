import Foundation

/// One Mac's record of its lists. The full record stays on the Mac (`sync-state.json`); what it writes
/// to `<sync folder>/devices/<device>.json` is `published()` — only the lists synced right now. Each
/// file has a single writer, so a sync service (iCloud Drive, Dropbox…) never sees a conflict.
///
/// It's a state-based CRDT: every synced field is a `Register` (newest stamp wins), deletes are
/// permanent markers in `deleted`, and `SyncMerge.merge` gives the same result in any order and any
/// number of times. Only content travels; where a note sits and whether it's open stay per Mac.
///
/// Whether a list syncs is itself a register (`sharing`), so turning it off on one Mac turns it off on
/// all of them. Every Mac keeps recording its own copy meanwhile, which is what lets turning it back on
/// merge the copies field by field instead of one overwriting the other.
///
/// Bump `schemaVersion` when the format changes **or an enum gains a case** (`NoteColor`,
/// `NoteMaterial`): a Mac that sees a newer schema skips that file and asks to be updated, instead
/// of misreading values it doesn't know.
struct SyncSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema = SyncSnapshot.schemaVersion
    var device: String
    var name: String
    /// When this Mac last published a *change* (ms since 1970) — the other Macs' "Latest changes" line.
    var writtenAt: Int64 = 0
    /// The highest stamp written or seen; the next stamp is always above it, so an edit made after
    /// seeing a change beats it even if this Mac's clock runs behind.
    var clock: Int64 = 0
    var notes: [String: SyncNote] = [:]
    var tasks: [String: SyncTask] = [:]
    /// Note id → whether that list syncs. Only lists that have ever synced have an entry.
    var sharing: [String: Register<Bool>] = [:]
    /// Deleted note and task ids → stamp. Kept for good, so no Mac can bring them back. Only things that
    /// were synced get one: deleting a list that never synced (or isn't synced now) is this Mac's business.
    var deleted: [String: Int64] = [:]

    func isShared(_ noteId: String) -> Bool { sharing[noteId]?.value ?? false }

    /// What goes in the sync folder: the lists synced now and their tasks, plus every sharing switch
    /// and deletion marker (ids only). A list that doesn't sync never leaves this Mac.
    func published() -> SyncSnapshot {
        var out = self
        out.notes = notes.filter { isShared($0.key) }
        out.tasks = tasks.filter { out.notes[$0.value.noteId] != nil }
        return out
    }

    /// The same lists, ignoring who wrote them and when — "did anything actually change?"
    func sameContent(as other: SyncSnapshot) -> Bool {
        notes == other.notes && tasks == other.tasks && sharing == other.sharing && deleted == other.deleted
    }
}

/// A value plus the stamp of its last change (ms since 1970).
struct Register<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value
    var stamp: Int64
}

struct SyncNote: Codable, Equatable, Sendable {
    var createdAt: Int64
    var title: Register<String>
    var color: Register<String>
    var material: Register<String>
    var hideCompleted: Register<Bool>
    var moveCompletedToBottom: Register<Bool>
    /// Task order *and* nesting as one value, so two reorders never interleave into a jumble.
    var outline: Register<[OutlineEntry]>
}

struct OutlineEntry: Codable, Equatable, Sendable {
    var id: String
    var level: Int
}

struct SyncTask: Codable, Equatable, Sendable {
    var noteId: String
    var createdAt: Int64
    var text: Register<String>
    var done: Register<Completion>
    /// The task's image (nil: none). The bytes travel as `<folder>/images/<hash>.png`.
    var image: Register<SyncImage?>
}

/// `isDone` and `completedAt` change together, so they're one register.
struct Completion: Codable, Equatable, Sendable {
    var isDone: Bool
    var completedAt: Int64?
}

/// A task's image: which picture (its content hash) and the crop over it (0…1, top-left origin).
struct SyncImage: Codable, Equatable, Sendable {
    var hash: String
    var cropX: Double
    var cropY: Double
    var cropW: Double
    var cropH: Double
}

/// The synced fields of this Mac's database (or what a snapshot means for it): the plain-value
/// side of `SyncSnapshot`, keyed by uuid string. `outline` is the note's tasks in display order.
/// A note's own `sortIndex` (creation order in the Lists menu) stays per Mac, like its frame.
struct SyncLocal: Equatable, Sendable {
    struct NoteFields: Equatable, Sendable {
        var createdAt: Int64
        var title: String
        var color: String
        var material: String
        var hideCompleted: Bool
        var moveCompletedToBottom: Bool
        var outline: [OutlineEntry]
        var isSynced: Bool
    }

    struct TaskFields: Equatable, Sendable {
        var noteId: String
        var createdAt: Int64
        var text: String
        var done: Completion
        var image: SyncImage?
    }

    var notes: [String: NoteFields] = [:]
    var tasks: [String: TaskFields] = [:]
}

/// What a sync cycle must write to make the database match a merged snapshot.
struct SyncChanges: Equatable, Sendable {
    var deletedNotes: [String] = []
    var deletedTasks: [String] = []
    var insertedNotes: [String] = []
    var updatedNotes: [String] = []
    /// Notes whose sync switch changed (turned on or off on another Mac).
    var syncFlags: [String] = []
    var insertedTasks: [String] = []
    var updatedTasks: [String] = []
    /// Tasks whose image must be added, replaced, re-cropped or removed.
    var images: [String] = []
    /// Notes whose task order or nesting must be rewritten (includes every note that gained tasks).
    var outlines: [String] = []

    var isEmpty: Bool { self == SyncChanges() }
}

extension Date {
    /// Whole milliseconds since 1970 — how sync stores dates, so a round trip through the database's
    /// millisecond text dates compares equal.
    var syncMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(syncMillis: Int64) { self.init(timeIntervalSince1970: Double(syncMillis) / 1000) }
}
