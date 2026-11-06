import CryptoKit
import Foundation
import GRDB

// MARK: - Tasks and task images

extension AppDatabase {
    // MARK: - Tasks

    func task(id: UUID) async throws -> TaskItem? {
        try await dbQueue.read { db in try TaskItem.filter(TaskItem.Columns.id == id).fetchOne(db) }
    }

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
    /// `imageData`, if given, is stored as the task's image in the same transaction.
    func insertTask(_ task: TaskItem, imageData: Data? = nil) async throws {
        let snapshot = task
        try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(
                db, sql: "SELECT MAX(sortIndex) FROM task WHERE noteId = ?", arguments: [snapshot.noteId]
            ) ?? -1
            var stored = snapshot
            stored.sortIndex = maxIndex + 1
            try stored.insert(db)
            if let imageData { try Self.writeImage(imageData, taskId: stored.id, db) }
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

    // MARK: - Task images

    /// Stores (or replaces) a task's image. A replaced picture starts uncropped again.
    func setTaskImage(taskId: UUID, data: Data) async throws {
        try await dbQueue.write { db in try Self.writeImage(data, taskId: taskId, db) }
    }

    /// `INSERT OR REPLACE` swaps the whole row, so the crop columns fall back to their full-image defaults.
    private static func writeImage(_ data: Data, taskId: UUID, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO taskImage (taskId, data, hash, updatedAt) VALUES (?, ?, ?, ?)",
            arguments: [taskId, data, imageHash(data), Date()]
        )
    }

    /// SHA-256 of an image's bytes, hex: its identity across Macs and its file name in the sync folder.
    static func imageHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Targeted write of just an image's crop, so it can't race a replace or a task text commit.
    func updateTaskImageCrop(taskId: UUID, crop: CGRect) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE taskImage SET cropX = ?, cropY = ?, cropW = ?, cropH = ?, updatedAt = ? WHERE taskId = ?",
                arguments: [
                    Double(crop.minX), Double(crop.minY), Double(crop.width), Double(crop.height), Date(), taskId,
                ]
            )
        }
    }

    /// Removes a task's image, keeping the task.
    func deleteTaskImage(taskId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM taskImage WHERE taskId = ?", arguments: [taskId])
        }
    }

    /// Whether a task has an image (a cheap existence check, never loads the blob).
    func hasImage(taskId: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM taskImage WHERE taskId = ?", arguments: [taskId]) ?? false
        }
    }

    /// The ids of a note's tasks that have an image — a one-shot for `get_note` (the observation twin
    /// is `observeTaskImageCrops`).
    func taskImageIds(noteId: UUID) async throws -> Set<UUID> {
        try await dbQueue.read { db in
            Set(try UUID.fetchAll(db, sql: """
                SELECT i.taskId FROM taskImage i JOIN task t ON t.id = i.taskId WHERE t.noteId = ?
                """, arguments: [noteId]))
        }
    }

    /// The stored (original, uncropped) image bytes — read on demand, never via an observation.
    func taskImageData(taskId: UUID) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM taskImage WHERE taskId = ?", arguments: [taskId])
        }
    }

    /// Emits the crop and content hash of every image in a note, keyed by task id. Deliberately never
    /// selects `data`, so the blobs are only read on demand (`taskImageData`). The hash is what tells the
    /// controller an image was replaced (say, from another Mac) when its crop didn't change.
    func observeTaskImageCrops(noteId: UUID) -> AsyncValueObservation<[UUID: TaskImageState]> {
        ValueObservation
            .tracking { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.taskId, i.cropX, i.cropY, i.cropW, i.cropH, i.hash
                    FROM taskImage i JOIN task t ON t.id = i.taskId
                    WHERE t.noteId = ?
                    """, arguments: [noteId])
                return Dictionary(uniqueKeysWithValues: rows.map { row in
                    let crop = CGRect(
                        x: row["cropX"] as Double, y: row["cropY"] as Double,
                        width: row["cropW"] as Double, height: row["cropH"] as Double
                    )
                    return (row["taskId"] as UUID, TaskImageState(crop: crop, hash: row["hash"]))
                })
            }
            .values(in: dbQueue)
    }
}

/// What `observeTaskImageCrops` reports per image: its crop, and its content hash (nil until computed).
struct TaskImageState: Equatable, Sendable {
    var crop: CGRect
    var hash: String?
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
