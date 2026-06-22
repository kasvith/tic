import Foundation
import Observation

/// Drives a single note window: holds the note's current state, streams its tasks live from the
/// database, and turns user actions into (targeted) database writes. One controller per open
/// note, owned by `NoteWindowManager` for the window's lifetime.
@MainActor
@Observable
final class NoteController {
    let noteID: UUID
    private(set) var note: Note
    private(set) var tasks: [TaskItem] = []

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// Re-applies window behaviour (floatOnTop, showOnAllSpaces) to the live panel. Set by
    /// `NoteWindowManager` so the controller stays AppKit-free.
    @ObservationIgnored var onApplyBehavior: ((Bool, Bool) -> Void)?

    /// Asks the manager to close (hide) this note's panel. Does NOT delete the note.
    @ObservationIgnored var onClose: (() -> Void)?

    /// Asks the manager to roll the live panel up/down to match `isCollapsed`.
    @ObservationIgnored var onSetCollapsed: ((Bool) -> Void)?

    /// Asks the manager to create a brand-new note (the in-note "+" button).
    @ObservationIgnored var onNewNote: (() -> Void)?

    init(note: Note, database: AppDatabase) {
        self.noteID = note.id
        self.note = note
        self.db = database
    }

    /// Begins streaming this note's tasks; each emission replaces `tasks` and updates the UI.
    func start() {
        observation?.cancel()
        observation = Task { [weak self, db, noteID] in
            do {
                for try await items in db.observeTasks(noteId: noteID) {
                    self?.tasks = items
                }
            } catch {
                NSLog("[Tic] task observation ended for \(noteID): \(error)")
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    // MARK: - Task actions

    /// Adds a task at the end. `level` is the requested nesting depth (from the quick-add field's
    /// pending indent); it's clamped to what the previous row allows so the outline stays valid.
    func addTask(_ rawText: String, level: Int = 0) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let maxLevel = tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        let clamped = min(max(level, 0), maxLevel)
        let task = TaskItem(noteId: noteID, text: text, sortIndex: tasks.count, indentLevel: clamped)
        tasks = tasks + [task]   // optimistic so the row appears instantly
        Task { [db] in try? await db.insertTask(task) }   // insertTask assigns the real sortIndex (MAX+1)
    }

    /// Inserts an empty subtask one level under `parent`, positioned right after `parent`'s existing
    /// subtree, and returns its id so the view can drop straight into editing it. (An empty task that
    /// never gets text is removed on commit, just like clearing a row.) No-op past the depth cap.
    @discardableResult
    func addSubtask(under parent: TaskItem) -> UUID? {
        guard let parentIndex = tasks.firstIndex(where: { $0.id == parent.id }) else { return nil }
        guard parent.indentLevel < TaskItem.maxIndentLevel else { return nil }
        let insertAt = TaskOutline.subtreeRange(tasks, at: parentIndex).upperBound
        let task = TaskItem(
            noteId: noteID, text: "", sortIndex: insertAt, indentLevel: parent.indentLevel + 1
        )
        var ordered = tasks
        ordered.insert(task, at: insertAt)
        tasks = ordered   // optimistic
        let snapshot = task
        let orderedSnapshot = ordered
        Task { [db] in try? await db.insertTask(snapshot, reordering: orderedSnapshot) }
        return task.id
    }

    /// Toggles a task's checkbox. Completion cascades down its subtree and bubbles up to ancestors
    /// (see `TaskOutline.applyingToggle`); only the rows that actually changed are written, and
    /// only their completion columns, so nothing clobbers a concurrent text edit.
    func toggle(_ task: TaskItem) {
        let updated = TaskOutline.applyingToggle(tasks, toggling: task.id, now: Date())
        let changes = completionChanges(from: tasks, to: updated)
        guard !changes.isEmpty else { return }
        tasks = updated   // optimistic; the observation confirms
        Task { [db] in try? await db.updateTaskCompletion(changes) }
    }

    /// Makes the task a subtask of the row above it (one level deeper), carrying any of its own
    /// subtasks along. No-op at the start of the list or once at the maximum depth.
    func indent(_ task: TaskItem) {
        applyStructural(TaskOutline.indenting(tasks, id: task.id))
    }

    /// Promotes the task one level out, carrying its subtasks along. No-op when already top-level.
    func outdent(_ task: TaskItem) {
        applyStructural(TaskOutline.outdenting(tasks, id: task.id))
    }

    func commitText(_ task: TaskItem, _ rawText: String) {
        // Trim only the outer whitespace/newlines; interior newlines are kept (multiline tasks).
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank (or whitespace-only) task is never kept — an abandoned new row just disappears.
        // Checked before the "unchanged" guard so a freshly-added empty row (whose stored text is
        // also empty) still gets removed on blur instead of lingering.
        if text.isEmpty {
            delete(task)
            return
        }
        guard text != task.text else { return }
        var updated = task
        updated.text = text
        let snapshot = updated
        Task { [db] in try? await db.update(snapshot) }
    }

    /// Deletes a single task. Its subtasks are kept (not cascade-deleted); the survivors are
    /// renormalised so a now-orphaned subtask can't render at an impossible depth. Tick states are
    /// left as-is (structural edits never change completion).
    func delete(_ task: TaskItem) {
        let id = task.id
        let survivors = tasks.filter { $0.id != id }
        applyStructural(TaskOutline.normalizedLevels(survivors), deleteId: id)
    }

    /// Moves the task with `id` — and its whole subtree — so it lands at `insertionIndex` (an index
    /// into the *current* ordering, 0...count), optionally re-nesting it to `targetLevel` (the
    /// horizontal drag-to-nest). Called once on drop, not continuously during the drag.
    func moveTask(id: UUID, toInsertionIndex insertionIndex: Int, targetLevel: Int? = nil) {
        let reordered = TaskOutline.movingSubtree(
            tasks, id: id, toInsertionIndex: insertionIndex, targetLevel: targetLevel
        )
        guard reordered != tasks else { return }   // no reorder and no re-nest → nothing to do
        applyStructural(TaskOutline.normalizedLevels(reordered), reorder: true)
    }

    // MARK: - Structural helpers

    /// Applies a structural edit, where `updated` is the new (already-normalised) task list. It
    /// changes only nesting and order — **never tick state**: moving/indenting/deleting a task
    /// preserves every checkbox exactly (completion only ever changes via an explicit `toggle`).
    ///
    /// Indent-level deltas are diffed **by id against the current `tasks`** (the DB-backed state) —
    /// not by position — so a reorder that also re-nests still persists every changed level. The UI
    /// updates optimistically and the (optional) delete / reorder + level changes are written in one
    /// transaction so the observation only ever sees a valid outline.
    private func applyStructural(_ updated: [TaskItem], deleteId: UUID? = nil, reorder: Bool = false) {
        let levels = TaskOutline.indentLevelChanges(from: tasks, to: updated)
            .map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        // For a pure indent/outdent (no delete, no reorder) bail when nothing actually changed.
        guard deleteId != nil || reorder || !levels.isEmpty else { return }
        tasks = updated   // optimistic; the observation confirms
        let ordered = reorder ? updated : nil
        Task { [db] in
            try? await db.applyStructuralUpdate(deleteId: deleteId, reorder: ordered, levels: levels)
        }
    }

    /// The `isDone`/`completedAt` deltas between two same-ordered task lists.
    private func completionChanges(from before: [TaskItem], to after: [TaskItem]) -> [TaskCompletionUpdate] {
        zip(before, after).compactMap { b, a in
            guard b.isDone != a.isDone || b.completedAt != a.completedAt else { return nil }
            return TaskCompletionUpdate(id: a.id, isDone: a.isDone, completedAt: a.completedAt)
        }
    }

    // MARK: - Note actions

    func commitTitle(_ rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != note.title else { return }
        note.title = title
        let id = noteID
        Task { [db] in try? await db.updateNoteTitle(id: id, title: title) }
    }

    // MARK: - Appearance

    func setColor(_ color: NoteColor) {
        guard color != note.color else { return }
        note.color = color
        let id = noteID
        let material = note.material
        Task { [db] in try? await db.updateNoteAppearance(id: id, color: color, material: material) }
    }

    func setMaterial(_ material: NoteMaterial) {
        guard material != note.material else { return }
        note.material = material
        let id = noteID
        let color = note.color
        Task { [db] in try? await db.updateNoteAppearance(id: id, color: color, material: material) }
    }

    func toggleMaterial() {
        setMaterial(note.material == .solid ? .glass : .solid)
    }

    // MARK: - Behaviour flags

    func toggleFloatOnTop() {
        note.floatOnTop.toggle()
        let id = noteID
        let floatOnTop = note.floatOnTop
        let showOnAllSpaces = note.showOnAllSpaces
        let isCollapsed = note.isCollapsed
        onApplyBehavior?(floatOnTop, showOnAllSpaces)   // update the live window at once
        Task { [db] in
            try? await db.updateNoteFlags(
                id: id, floatOnTop: floatOnTop,
                showOnAllSpaces: showOnAllSpaces, isCollapsed: isCollapsed
            )
        }
    }

    /// Rolls the note up to just its title bar (or back down), like Stickies.
    func toggleCollapsed() {
        note.isCollapsed.toggle()
        let id = noteID
        let collapsed = note.isCollapsed
        let floatOnTop = note.floatOnTop
        let showOnAllSpaces = note.showOnAllSpaces
        onSetCollapsed?(collapsed)   // resize the live window at once
        Task { [db] in
            try? await db.updateNoteFlags(
                id: id, floatOnTop: floatOnTop,
                showOnAllSpaces: showOnAllSpaces, isCollapsed: collapsed
            )
        }
    }

    // MARK: - Lifecycle

    /// Hides this note (closes its panel). The note stays in the DB and reopens next launch.
    func requestClose() {
        onClose?()
    }

    /// Creates a new, separate note.
    func requestNewNote() {
        onNewNote?()
    }
}
