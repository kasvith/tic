import Foundation
import GRDB

/// The database half of sync between Macs (`FolderSync` does the files, `SyncMerge` the rules).
extension AppDatabase {
    struct SyncCycle: Sendable {
        /// This Mac's record after taking in local edits and merging the other Macs. The database now
        /// holds `SyncMerge.resolve(snapshot)` for every list that syncs.
        var snapshot: SyncSnapshot
        var changes: SyncChanges
        /// Images another Mac added whose bytes haven't reached this Mac's folder yet (left for a later
        /// cycle, without being mistaken for a removal here).
        var waitingImages: Int
    }

    /// One sync step in a single write transaction, so no edit can land between reading the
    /// database and applying the merge: record local edits into `mine`, merge `others`, then write
    /// the difference. Only synced columns of synced lists are touched — a note's frame, open state and
    /// window flags never change here, and lists that arrive from another Mac are inserted closed.
    /// `images` holds the bytes of pictures the merge may need (hash → PNG), read from the folder.
    func syncCycle(
        mine: SyncSnapshot, others: [SyncSnapshot], images: [String: Data] = [:], now: Int64
    ) async throws -> SyncCycle {
        try await dbQueue.write { db in
            let local = try Self.syncLocal(db)
            let deletedUnsynced = Set(try UUID.fetchAll(db, sql: "SELECT noteId FROM syncLocalDelete")
                .map(\.uuidString))
            let recorded = SyncMerge.record(local, into: mine, now: now, deletedUnsynced: deletedUnsynced)
            try db.execute(sql: "DELETE FROM syncLocalDelete")
            var merged = others.reduce(recorded, SyncMerge.merge)
            var target = SyncMerge.resolve(merged)
            var changes = SyncMerge.changes(from: local, to: target, deleted: merged.deleted)

            // A picture whose file is still on its way: keep this Mac's own register for now, so the
            // database and the record agree. The other Mac's file still has it; a later cycle takes it.
            let waiting = try changes.images.filter { id in
                guard let image = target.tasks[id]?.image, local.tasks[id]?.image?.hash != image.hash else {
                    return false
                }
                return try images[image.hash] == nil && !Self.hasImage(hash: image.hash, db)
            }
            if !waiting.isEmpty {
                for id in waiting {
                    merged.tasks[id]?.image = recorded.tasks[id]?.image ?? Register(value: nil, stamp: 0)
                }
                target = SyncMerge.resolve(merged)
                changes = SyncMerge.changes(from: local, to: target, deleted: merged.deleted)
            }

            if !changes.isEmpty { try Self.apply(changes, target: target, images: images, db) }
            return SyncCycle(snapshot: merged, changes: changes, waitingImages: waiting.count)
        }
    }

    /// Calls `onChange` after any commit that touches a synced column — not frame drags or the open
    /// flag, which happen far more often and never travel.
    func observeSyncedChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyDatabaseCancellable {
        DatabaseRegionObservation(tracking:
            Note.select(Column("title"), Column("color"), Column("material"),
                        Column("hideCompleted"), Column("moveCompletedToBottom"), Column("isSynced")),
            TaskItem.all(),
            Table("taskImage").select(Column("hash"), Column("cropX"), Column("cropY"),
                                      Column("cropW"), Column("cropH"))
        )
        .start(in: dbQueue, onError: { NSLog("[Tic] sync observation failed: \($0)") }, onChange: { _ in onChange() })
    }

    /// The content hashes of every image this Mac holds (to know which files to fetch).
    func syncImageHashes() async throws -> Set<String> {
        try await dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT DISTINCT hash FROM taskImage WHERE hash IS NOT NULL")
        }
    }

    /// The bytes of an image by content hash (to publish it to the folder).
    func syncImageData(hash: String) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM taskImage WHERE hash = ? LIMIT 1", arguments: [hash])
        }
    }

    static func syncLocal(_ db: Database) throws -> SyncLocal {
        // Images saved before hashes existed get theirs now — once, inside this write.
        for row in try Row.fetchAll(db, sql: "SELECT taskId, data FROM taskImage WHERE hash IS NULL") {
            try db.execute(sql: "UPDATE taskImage SET hash = ? WHERE taskId = ?",
                           arguments: [imageHash(row["data"]), row["taskId"] as UUID])
        }
        var images: [UUID: SyncImage] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT taskId, hash, cropX, cropY, cropW, cropH FROM taskImage") {
            images[row["taskId"]] = SyncImage(hash: row["hash"], cropX: row["cropX"], cropY: row["cropY"],
                                              cropW: row["cropW"], cropH: row["cropH"])
        }

        var out = SyncLocal()
        var byNote: [UUID: [TaskItem]] = [:]
        for t in try TaskItem.fetchAll(db) {
            out.tasks[t.id.uuidString] = SyncLocal.TaskFields(
                noteId: t.noteId.uuidString, createdAt: t.createdAt.syncMillis, text: t.text,
                done: Completion(isDone: t.isDone, completedAt: t.completedAt?.syncMillis),
                image: images[t.id]
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
                outline: ordered.map { OutlineEntry(id: $0.id.uuidString, level: $0.indentLevel) },
                isSynced: n.isSynced
            )
        }
        return out
    }

    private static func hasImage(hash: String, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT 1 FROM taskImage WHERE hash = ? LIMIT 1", arguments: [hash]) ?? false
    }

    private static func apply(_ c: SyncChanges, target: SyncLocal, images: [String: Data], _ db: Database) throws {
        let now = Date()
        try applyNotes(c, target: target, db, now: now)
        try applyTasks(c, target: target, images: images, db, now: now)
    }

    private static func applyNotes(_ c: SyncChanges, target: SyncLocal, _ db: Database, now: Date) throws {
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
                hideCompleted: n.hideCompleted, moveCompletedToBottom: n.moveCompletedToBottom, isSynced: true
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
        for key in c.syncFlags {
            guard let id = UUID(uuidString: key), let n = target.notes[key] else { continue }
            try db.execute(sql: "UPDATE note SET isSynced = ? WHERE id = ?", arguments: [n.isSynced, id])
        }
    }

    private static func applyTasks(
        _ c: SyncChanges, target: SyncLocal, images: [String: Data], _ db: Database, now: Date
    ) throws {
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
        for key in c.images {
            guard let id = UUID(uuidString: key), let t = target.tasks[key] else { continue }
            try applyImage(t.image, taskId: id, images: images, db, now: now)
        }
        for key in c.outlines {
            for (index, entry) in (target.notes[key]?.outline ?? []).enumerated() {
                guard let id = UUID(uuidString: entry.id) else { continue }
                try db.execute(sql: "UPDATE task SET sortIndex = ?, indentLevel = ? WHERE id = ?",
                               arguments: [index, entry.level, id])
            }
        }
    }

    /// Removes, re-crops or (re)places a task's image. Bytes come from the folder (`images`) or from any
    /// task here that already has the same picture.
    private static func applyImage(
        _ image: SyncImage?, taskId: UUID, images: [String: Data], _ db: Database, now: Date
    ) throws {
        guard let image else {
            try db.execute(sql: "DELETE FROM taskImage WHERE taskId = ?", arguments: [taskId])
            return
        }
        let current = try String.fetchOne(db, sql: "SELECT hash FROM taskImage WHERE taskId = ?", arguments: [taskId])
        if current == image.hash {
            try db.execute(
                sql: "UPDATE taskImage SET cropX = ?, cropY = ?, cropW = ?, cropH = ?, updatedAt = ? WHERE taskId = ?",
                arguments: [image.cropX, image.cropY, image.cropW, image.cropH, now, taskId]
            )
            return
        }
        let bytes = try images[image.hash]
            ?? Data.fetchOne(db, sql: "SELECT data FROM taskImage WHERE hash = ? LIMIT 1", arguments: [image.hash])
        guard let bytes else { return }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO taskImage (taskId, data, hash, cropX, cropY, cropW, cropH, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [taskId, bytes, image.hash, image.cropX, image.cropY, image.cropW, image.cropH, now]
        )
    }
}
