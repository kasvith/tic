import Foundation
import GRDB

/// The database half of sync between Macs (`FolderSync` does the files, `SyncMerge` the rules).
extension AppDatabase {
    struct SyncCycle: Sendable {
        /// This Mac's snapshot after recording local edits and merging the other Macs in. The
        /// database now holds exactly `SyncMerge.resolve(snapshot)`.
        var snapshot: SyncSnapshot
        var changes: SyncChanges
    }

    /// One sync step in a single write transaction, so no edit can land between reading the
    /// database and applying the merge: record local edits into `mine`, merge `others`, then write
    /// the difference. Only synced columns are touched — a note's frame, open state and window flags
    /// never change here, and lists that arrive from another Mac are inserted closed.
    func syncCycle(mine: SyncSnapshot, others: [SyncSnapshot], now: Int64) async throws -> SyncCycle {
        try await dbQueue.write { db in
            let local = try Self.syncLocal(db)
            let recorded = SyncMerge.record(local, into: mine, now: now)
            let merged = others.reduce(recorded, SyncMerge.merge)
            let target = SyncMerge.resolve(merged)
            let changes = SyncMerge.changes(from: local, to: target)
            if !changes.isEmpty { try Self.apply(changes, target: target, db) }
            return SyncCycle(snapshot: merged, changes: changes)
        }
    }

    /// Calls `onChange` after any commit that touches a synced column — not frame drags or the open
    /// flag, which happen far more often and never travel.
    func observeSyncedChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyDatabaseCancellable {
        DatabaseRegionObservation(tracking:
            Note.select(Column("title"), Column("color"), Column("material"),
                        Column("hideCompleted"), Column("moveCompletedToBottom")),
            TaskItem.all()
        )
        .start(in: dbQueue, onError: { NSLog("[Tic] sync observation failed: \($0)") }, onChange: { _ in onChange() })
    }

    static func syncLocal(_ db: Database) throws -> SyncLocal {
        var out = SyncLocal()
        var byNote: [UUID: [TaskItem]] = [:]
        for t in try TaskItem.fetchAll(db) {
            out.tasks[t.id.uuidString] = SyncLocal.TaskFields(
                noteId: t.noteId.uuidString, createdAt: t.createdAt.syncMillis, text: t.text,
                done: Completion(isDone: t.isDone, completedAt: t.completedAt?.syncMillis)
            )
            byNote[t.noteId, default: []].append(t)
        }
        for n in try Note.fetchAll(db) {
            let ordered = (byNote[n.id] ?? [])
                .sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
            out.notes[n.id.uuidString] = SyncLocal.NoteFields(
                createdAt: n.createdAt.syncMillis, title: n.title, color: n.color.rawValue,
                material: n.material.rawValue, hideCompleted: n.hideCompleted,
                moveCompletedToBottom: n.moveCompletedToBottom,
                outline: ordered.map { OutlineEntry(id: $0.id.uuidString, level: $0.indentLevel) }
            )
        }
        return out
    }

    private static func apply(_ c: SyncChanges, target: SyncLocal, _ db: Database) throws {
        let now = Date()
        for id in c.deletedTasks.compactMap(UUID.init(uuidString:)) {
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id])
        }
        for id in c.deletedNotes.compactMap(UUID.init(uuidString:)) {
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id])
        }
        for key in c.insertedNotes {
            guard let id = UUID(uuidString: key), let n = target.notes[key] else { continue }
            let nextIndex = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM note") ?? -1) + 1
            try Note(
                id: id, title: n.title, createdAt: Date(syncMillis: n.createdAt), updatedAt: now,
                color: NoteColor(rawValue: n.color) ?? .yellow, material: NoteMaterial(rawValue: n.material) ?? .solid,
                isOpen: false, sortIndex: nextIndex,
                hideCompleted: n.hideCompleted, moveCompletedToBottom: n.moveCompletedToBottom
            ).insert(db)
        }
        for key in c.updatedNotes {
            guard let id = UUID(uuidString: key), let n = target.notes[key] else { continue }
            try db.execute(
                sql: """
                    UPDATE note SET title = ?, color = ?, material = ?, hideCompleted = ?,
                    moveCompletedToBottom = ?, updatedAt = ? WHERE id = ?
                    """,
                arguments: [n.title, n.color, n.material, n.hideCompleted, n.moveCompletedToBottom, now, id]
            )
        }
        for key in c.insertedTasks {
            guard let id = UUID(uuidString: key), let t = target.tasks[key],
                  let noteId = UUID(uuidString: t.noteId) else { continue }
            // Placed by the outline pass below (every note that gains a task is in `c.outlines`).
            try TaskItem(
                id: id, noteId: noteId, text: t.text, isDone: t.done.isDone,
                createdAt: Date(syncMillis: t.createdAt), completedAt: t.done.completedAt.map(Date.init(syncMillis:))
            ).insert(db)
        }
        for key in c.updatedTasks {
            guard let id = UUID(uuidString: key), let t = target.tasks[key] else { continue }
            try db.execute(
                sql: "UPDATE task SET text = ?, isDone = ?, completedAt = ? WHERE id = ?",
                arguments: [t.text, t.done.isDone, t.done.completedAt.map(Date.init(syncMillis:)), id]
            )
        }
        for key in c.outlines {
            for (index, entry) in (target.notes[key]?.outline ?? []).enumerated() {
                guard let id = UUID(uuidString: entry.id) else { continue }
                try db.execute(sql: "UPDATE task SET sortIndex = ?, indentLevel = ? WHERE id = ?",
                               arguments: [index, entry.level, id])
            }
        }
    }
}
