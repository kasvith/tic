import Foundation

/// One Mac's copy of every list, written to `<sync folder>/devices/<device>.json` and nowhere else —
/// each file has a single writer, so a sync service (iCloud Drive, Dropbox…) never sees a conflict.
///
/// It's a state-based CRDT: every synced field is a `Register` (newest stamp wins), deletes are
/// permanent markers in `deleted`, and `SyncMerge.merge` gives the same result in any order and any
/// number of times. Only content travels; where a note sits and whether it's open stay per Mac.
///
/// Bump `schemaVersion` when the format changes **or an enum gains a case** (`NoteColor`,
/// `NoteMaterial`): a Mac that sees a newer schema skips that file and asks to be updated, instead
/// of misreading values it doesn't know.
struct SyncSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema = SyncSnapshot.schemaVersion
    var device: String
    var name: String
    /// When this Mac last wrote a *change* (ms since 1970) — the other Macs' "Latest changes" line.
    var writtenAt: Int64 = 0
    /// The highest stamp written or seen; the next stamp is always above it, so an edit made after
    /// seeing a change beats it even if this Mac's clock runs behind.
    var clock: Int64 = 0
    var notes: [String: SyncNote] = [:]
    var tasks: [String: SyncTask] = [:]
    /// Deleted note and task ids → stamp. Kept for good, so no Mac can bring them back.
    var deleted: [String: Int64] = [:]

    /// The same content, ignoring who wrote it and when — "did anything actually change?"
    func sameContent(as other: SyncSnapshot) -> Bool {
        clock == other.clock && notes == other.notes && tasks == other.tasks && deleted == other.deleted
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
}

/// `isDone` and `completedAt` change together, so they're one register.
struct Completion: Codable, Equatable, Sendable {
    var isDone: Bool
    var completedAt: Int64?
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
    }

    struct TaskFields: Equatable, Sendable {
        var noteId: String
        var createdAt: Int64
        var text: String
        var done: Completion
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
    var insertedTasks: [String] = []
    var updatedTasks: [String] = []
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
