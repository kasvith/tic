import Foundation

/// Pure, side-effect-free outline maths over a note's flat, `sortIndex`-ordered `[TaskItem]`.
///
/// The list is kept flat on purpose (see `TaskItem.indentLevel`): a task's **parent** is the
/// nearest preceding task with a smaller `indentLevel`, and its **subtree** is the contiguous run
/// of following tasks with a strictly greater level. Every function here preserves the *outline
/// invariant* — the first task is level 0 and no task is more than one level deeper than the task
/// above it — so the list always renders as a valid, gap-free tree.
///
/// Kept separate from `NoteController` (which owns the DB writes) so the tree logic is unit-testable
/// without a database or the main actor.
enum TaskOutline {
    // MARK: - Structure queries

    /// The half-open index range covering the task at `index` **and all of its descendants**
    /// (`index ..< end`). The descendants alone are `index + 1 ..< end`.
    static func subtreeRange(_ tasks: [TaskItem], at index: Int) -> Range<Int> {
        guard tasks.indices.contains(index) else { return index..<index }
        let level = tasks[index].indentLevel
        var end = index + 1
        while end < tasks.count, tasks[end].indentLevel > level { end += 1 }
        return index..<end
    }

    /// The index of the nearest preceding task one or more levels shallower — the implicit parent.
    /// `nil` for a top-level task (level 0) or when none is found.
    static func parentIndex(_ tasks: [TaskItem], of index: Int) -> Int? {
        guard tasks.indices.contains(index) else { return nil }
        let level = tasks[index].indentLevel
        guard level > 0 else { return nil }
        var i = index - 1
        while i >= 0 {
            if tasks[i].indentLevel < level { return i }
            i -= 1
        }
        return nil
    }

    /// Indices of the *direct* children of the task at `index` (level exactly one deeper).
    static func directChildren(_ tasks: [TaskItem], of index: Int) -> [Int] {
        let range = subtreeRange(tasks, at: index)
        let childLevel = tasks[index].indentLevel + 1
        return range.dropFirst().filter { tasks[$0].indentLevel == childLevel }
    }

    // MARK: - Completion

    /// Toggles the task identified by `id` and returns the updated list.
    ///
    /// Completion flows **both ways**:
    /// - *Top-down*: the toggled task and its whole subtree are set to the new state.
    /// - *Bottom-up*: each ancestor is then recomputed as done **iff all of its direct children
    ///   are done**, so finishing the last subtask auto-completes the parent and reopening any
    ///   subtask reopens it.
    ///
    /// `completedAt` is stamped with `now` only on the transition *into* done and cleared when
    /// leaving done; tasks already in the target state keep their existing timestamp.
    static func applyingToggle(_ tasks: [TaskItem], toggling id: UUID, now: Date) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        var out = tasks
        let target = !out[index].isDone

        // Top-down: the task plus every descendant.
        for j in subtreeRange(out, at: index) { setDone(&out[j], target, now: now) }

        // Bottom-up: walk parent → root, deriving each ancestor's state from its children.
        var child = index
        while let parent = parentIndex(out, of: child) {
            let allChildrenDone = directChildren(out, of: parent).allSatisfy { out[$0].isDone }
            setDone(&out[parent], allChildrenDone, now: now)
            child = parent
        }
        return out
    }

    /// Sets a task's done state only when it actually changes, stamping/clearing `completedAt`.
    private static func setDone(_ task: inout TaskItem, _ done: Bool, now: Date) {
        guard task.isDone != done else { return }
        task.isDone = done
        task.completedAt = done ? now : nil
    }

    // MARK: - Indenting

    /// Indents the task at `id` one level deeper (Shift-Tab), carrying its subtree with it.
    /// A no-op when the task is the first row or is already as deep as the row above allows.
    static func indenting(_ tasks: [TaskItem], id: UUID) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }), index > 0 else { return tasks }
        let maxAllowed = min(TaskItem.maxIndentLevel, tasks[index - 1].indentLevel + 1)
        guard tasks[index].indentLevel < maxAllowed else { return tasks }
        return shiftingSubtree(tasks, at: index, by: 1)
    }

    /// Outdents the task at `id` one level (Ctrl-Shift-Tab), carrying its subtree with it.
    /// A no-op when the task is already top-level.
    static func outdenting(_ tasks: [TaskItem], id: UUID) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        guard tasks[index].indentLevel > 0 else { return tasks }
        return shiftingSubtree(tasks, at: index, by: -1)
    }

    /// Shifts a task and its descendants by `delta` levels (clamped to `0…maxIndentLevel`), then
    /// renormalises so the result is always a valid outline.
    private static func shiftingSubtree(_ tasks: [TaskItem], at index: Int, by delta: Int) -> [TaskItem] {
        var out = tasks
        for j in subtreeRange(out, at: index) {
            out[j].indentLevel = clamp(out[j].indentLevel + delta)
        }
        return normalizedLevels(out)
    }

    // MARK: - Moving

    /// Moves the task at `id` — together with its whole subtree — so it lands at `insertionIndex`
    /// (an index into the *current* ordering, `0...count`). Mirrors indent/outdent in carrying the
    /// nested rows along, so dragging a parent never strands its children.
    ///
    /// When `targetLevel` is given (a horizontal drag-to-nest), the moved block's head is shifted to
    /// that depth and its descendants shift by the same delta, so the drag can re-nest as well as
    /// reorder. Returns the reordered list (levels carried/shifted — caller should `normalizedLevels`
    /// afterwards to guarantee a valid tree).
    static func movingSubtree(
        _ tasks: [TaskItem], id: UUID, toInsertionIndex insertionIndex: Int, targetLevel: Int? = nil
    ) -> [TaskItem] {
        guard let from = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        let range = subtreeRange(tasks, at: from)
        var block = Array(tasks[range])
        if let targetLevel {
            let delta = clamp(targetLevel) - block[0].indentLevel
            for i in block.indices { block[i].indentLevel = clamp(block[i].indentLevel + delta) }
        }
        var remainder = tasks
        remainder.removeSubrange(range)
        // Translate the drop index (into the original list) into the post-removal list: subtract the
        // count of removed rows that sat before it.
        let removedBefore = max(0, min(range.upperBound, insertionIndex) - range.lowerBound)
        let target = min(max(insertionIndex - removedBefore, 0), remainder.count)
        remainder.insert(contentsOf: block, at: target)
        return remainder
    }

    // MARK: - Normalisation

    /// Forces the outline invariant: first task at level 0, every other task at most one level
    /// deeper than its predecessor, all within `0…maxIndentLevel`. Used after any structural change
    /// (indent, outdent, reorder, delete) so an orphaned or jumped level can never render.
    static func normalizedLevels(_ tasks: [TaskItem]) -> [TaskItem] {
        guard !tasks.isEmpty else { return tasks }
        var out = tasks
        out[0].indentLevel = 0
        for i in 1..<out.count {
            out[i].indentLevel = min(clamp(out[i].indentLevel), out[i - 1].indentLevel + 1)
        }
        return out
    }

    private static func clamp(_ level: Int) -> Int {
        min(max(level, 0), TaskItem.maxIndentLevel)
    }

    // MARK: - Diffing

    /// The `indentLevel` changes needed to turn `old` into `new`, matched **by id** (not position).
    /// Matching by id is what lets a reorder that also re-nests persist correctly: the new list is in
    /// a different order than the old one, so a positional diff would miss the level change.
    static func indentLevelChanges(from old: [TaskItem], to new: [TaskItem]) -> [(id: UUID, level: Int)] {
        let oldLevel = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.indentLevel) })
        return new.compactMap { task in
            guard let previous = oldLevel[task.id], previous != task.indentLevel else { return nil }
            return (task.id, task.indentLevel)
        }
    }
}
