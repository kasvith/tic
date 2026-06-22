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

    func addTask(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let task = TaskItem(noteId: noteID, text: text, sortIndex: tasks.count)
        Task { [db] in try? await db.insert(task) }
    }

    func toggle(_ task: TaskItem) {
        var updated = task
        updated.isDone.toggle()
        updated.completedAt = updated.isDone ? Date() : nil
        let snapshot = updated
        Task { [db] in try? await db.update(snapshot) }
    }

    func commitText(_ task: TaskItem, _ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != task.text else { return }
        if text.isEmpty {
            delete(task)
            return
        }
        var updated = task
        updated.text = text
        let snapshot = updated
        Task { [db] in try? await db.update(snapshot) }
    }

    func delete(_ task: TaskItem) {
        let id = task.id
        Task { [db] in try? await db.deleteTask(id: id) }
    }

    /// Moves the task with `id` so it lands at `insertionIndex` (an index into the *current*
    /// ordering, 0...count). Called once on drop, not continuously during the drag.
    func moveTask(id: UUID, toInsertionIndex insertionIndex: Int) {
        guard let from = tasks.firstIndex(where: { $0.id == id }) else { return }
        var reordered = tasks
        let item = reordered.remove(at: from)
        let target = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        let clamped = min(max(target, 0), reordered.count)
        reordered.insert(item, at: clamped)
        guard reordered.map(\.id) != tasks.map(\.id) else { return }
        tasks = reordered // optimistic; the observation confirms the persisted order
        let snapshot = reordered
        Task { [db] in try? await db.reorderTasks(snapshot) }
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
}
