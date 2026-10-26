import AppKit
import SwiftUI

/// Shared layout constants so the SwiftUI collapsed bar and the AppKit window resize agree.
enum NoteLayout {
    /// Height of a rolled-up note (shows only its title bar).
    static let collapsedHeight: CGFloat = 44
    /// Horizontal inset added per nesting level, so subtasks step to the right of their parent.
    static let indentStep: CGFloat = 20
    /// Horizontal inset of task rows from the note's edges — room for the drag grip and the drop
    /// highlight left of a top-level checkbox. Matches the title and the quick-add bar.
    static let rowInset: CGFloat = 16
}

/// The contents of a single sticky note: a hover-reveal header, a reorderable checklist, and a
/// quick-add field — or, when rolled up, just a compact title bar. State and persistence are
/// owned by `NoteController`.
///
/// The task list uses `ScrollView { VStack }` rather than `List` on purpose — a macOS `List`
/// is NSTableView-backed and draws a dark "emphasized" selection highlight behind a focused row,
/// which looked like an ugly black box when editing. A plain stack has no selection chrome.
///
/// It's a **non-lazy** `VStack` deliberately: each row's inline editor is an AppKit `NSTextView`
/// that owns its own first responder, and a `LazyVStack` culls/recreates rows as they cross the
/// viewport. During rapid-add a freshly-inserted row often lands just below the fold — a `LazyVStack`
/// wouldn't realise it, so it never began editing, never grabbed the keyboard, and couldn't be
/// scrolled to (no view to target). A `VStack` realises every row, so the new row exists, focuses,
/// and scrolls into view reliably. Note lists are short, so rendering them all costs nothing.
///
/// Reorder uses a direct `DragGesture` (not the system `.onDrag`, which has a sluggish pickup):
/// the dragged row (with its subtree) lifts and follows the cursor, the rest part around a ghost
/// placeholder at the exact landing spot and level, the receiving parent is tinted with an elbow
/// line into the placeholder, and the move commits once on release. (On macOS scrolling is the
/// wheel/trackpad, so a click-drag here doesn't fight the ScrollView.)
struct NoteView: View {
    @Bindable var controller: NoteController

    @State private var titleText: String
    @State private var revealed = false
    @State private var drag: ReorderDrag
    // True while a reorder gesture is live. SwiftUI resets it when the gesture ends *or is cancelled*;
    // a cancel never reaches `onEnded`, so this is what puts the task back instead of leaving it lifted.
    @GestureState private var reorderGestureActive = false
    @State private var rowFrames: [RowFrame] = []
    // The subtask currently being filled in the rapid-add flow. It both drives auto-focus (the row
    // whose id this matches grabs the keyboard) and chains the run: committing it with Return opens
    // the next sibling at the same level; an empty commit / Esc / blur ends the run. It persists for
    // the whole run — not a one-shot — so the active row keeps re-asserting editing/focus across
    // re-renders instead of landing dead after the first render.
    @State private var addingRowID: TaskItem.ID?
    // The heading whose group is currently hovered; drives the "Add subtask" affordance shown at the
    // bottom of that group. Holds the section root (level-0) id, so the affordance stays put as the
    // pointer moves across the heading, its children, and the affordance itself — it never darts away.
    @State private var activeSectionID: TaskItem.ID?
    // The task whose image is under the pointer or being cropped; its row's reorder drag is paused.
    @State private var imageInteractionTaskID: TaskItem.ID?
    @FocusState private var titleFocused: Bool

    private static let listSpace = "tic.tasklist"

    #if DEBUG
    /// Times the task list has been rebuilt; tests use it to check a drag doesn't redo it every frame.
    static var taskListRenders = 0
    #endif

    /// `drag` is injectable so tests can watch a reorder drag's state.
    init(controller: NoteController, drag: ReorderDrag = ReorderDrag()) {
        self.controller = controller
        _titleText = State(initialValue: controller.note.title)
        _drag = State(initialValue: drag)
    }

    private var note: Note { controller.note }
    private var isDragging: Bool { drag.taskID != nil }

    private var theme: NoteTheme {
        NoteTheme(color: note.color, surface: note.material == .glass ? .glass : .solid)
    }

    var body: some View {
        Group {
            if note.isCollapsed {
                collapsedBar
            } else {
                expandedBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoteBackground(color: note.color, material: note.material))
        .ignoresSafeArea()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { revealed = hovering }
        }
    }

    // MARK: - Collapsed bar

    private var collapsedBar: some View {
        let remaining = controller.tasks.filter { !$0.isDone }.count
        return HStack(spacing: 8) {
            Text(note.title.isEmpty ? "Untitled List" : note.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            if remaining > 0 {
                Text("\(remaining)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.18)))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)   // let the drag handle below receive all clicks
        .background(WindowMoveArea { controller.toggleCollapsed() })
        .help("Drag to move · double-click to expand")
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoteHeaderView(
                controller: controller,
                theme: theme,
                isRevealed: revealed,
                titleText: $titleText,
                titleFocused: $titleFocused
            )
            taskList
            QuickAddBar(controller: controller, theme: theme)
        }
    }

    // MARK: - Task list

    private var taskList: some View {
        // Everything below reasons in *displayed* space: the source-of-truth `tasks` with the note's
        // completed-display options applied. Equal to `controller.tasks` when both options are off.
        // Mid-drag the dragged block leaves the list and its head stands in as the drop placeholder.
        #if DEBUG
        Self.taskListRenders += 1
        #endif
        let display = isDragging ? dragRows : controller.displayedTasks
        let add = activeAdd
        let dropParent = dropParentID
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(display.enumerated()), id: \.element.id) { index, task in
                        row(task, isDropParent: task.id == dropParent)
                        if let add, add.afterIndex == index {
                            AddSubtaskRow(
                                theme: theme,
                                level: add.level,
                                onActivate: {
                                    if let parent = controller.tasks.first(where: { $0.id == add.parentID }) {
                                        startAdding(under: parent)
                                    }
                                },
                                onHoverChanged: { hovering in if hovering { activeSectionID = add.parentID } }
                            )
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 12)   // breathing room so the last row never crowds the quick-add bar
                .coordinateSpace(.named(Self.listSpace))
                .overlay(alignment: .topLeading) { dragOverlay(parentID: dropParent) }
                .onPreferenceChange(RowFrame.Key.self) { rowFrames = $0 }
            }
            .scrollContentBackground(.hidden)
            // A click on the empty space (anywhere not a row/field/button) ends editing — and a blank
            // row vanishes — rather than leaving the caret stuck in a field. Row taps take precedence.
            .contentShape(Rectangle())
            .onTapGesture { endEditing() }
            // Leaving the list dismisses the section's add affordance. Moving among a section's rows and
            // its affordance keeps it (each sets activeSectionID on enter), so it never darts away.
            .onHover { inside in
                if !inside { withAnimation(.easeInOut(duration: 0.12)) { activeSectionID = nil } }
            }
            // When a rapid-add opens the next row (Return, or the first click), bring it into view so
            // you can see what you're typing even when the new row would land below the fold. Once it's
            // realised, the row's window-entry hook (PlainTextEditor) grabs the keyboard.
            .onChange(of: addingRowID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newID, anchor: .bottom) }
            }
            .onChange(of: reorderGestureActive) { _, active in
                // Deferred a tick so a normal drop's `onEnded` (whichever order SwiftUI runs them in)
                // commits first; only a cancelled drag is still in flight here, and it's put back.
                if !active { Task { @MainActor in cancelDrag() } }
            }
            .onChange(of: controller.note.title) { _, newTitle in
                // An agent (or another writer) renamed the note: reflect it unless the user is mid-edit.
                if !titleFocused { titleText = newTitle }
            }
            .overlay(alignment: .top) {
                if display.isEmpty {
                    Text(controller.tasks.isEmpty
                         ? "No tasks yet — add one below" : "All done — completed tasks hidden")
                        .font(.callout)
                        .foregroundStyle(theme.secondary)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Resigns the editing text view, committing it (and removing it if blank). Used when the user
    /// clicks empty space instead of another row/field.
    private func endEditing() {
        addingRowID = nil   // a click away ends any rapid-add run
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Starts a rapid-add run under `parent`: inserts an empty subtask and drops into editing it.
    /// No-op past the depth cap (`addSubtask` returns nil, so the `+` did nothing).
    private func startAdding(under parent: TaskItem) {
        guard let id = controller.addSubtask(under: parent) else { return }
        addingRowID = id
    }

    /// Continues a rapid-add run: when the active add row is committed with Return, open a fresh
    /// sibling just below it at the same level and focus it. An empty row was already removed by the
    /// commit, so `addSibling` finds nothing and returns nil — which ends the run. Only the active
    /// add row continues, so editing an existing task and pressing Return never spawns a new row.
    private func continueAdding(after committed: TaskItem) {
        guard committed.id == addingRowID else { return }
        if let next = controller.addSibling(below: committed) {
            addingRowID = next
        } else {
            addingRowID = nil
        }
    }

    /// The level-0 heading that owns `task`'s group (itself if it's already top-level). The add
    /// affordance is scoped to this so it sits at the bottom of the whole section, stable while the
    /// pointer roams the section's rows.
    private func sectionRootID(of task: TaskItem) -> TaskItem.ID? {
        let display = controller.displayedTasks
        guard var i = display.firstIndex(where: { $0.id == task.id }) else { return nil }
        while i > 0, display[i].indentLevel > 0 { i -= 1 }
        return display[i].id
    }

    /// Where to show the "Add subtask" affordance: after the last row of the hovered heading's group,
    /// indented one level under the heading. Hidden during a drag or while a rapid-add run is already
    /// in progress (Return drives that, so the affordance would only be noise).
    private var activeAdd: ActiveAdd? {
        guard !isDragging, addingRowID == nil, let sectionID = activeSectionID else { return nil }
        let display = controller.displayedTasks
        guard let rootIndex = display.firstIndex(where: { $0.id == sectionID }) else { return nil }
        let root = display[rootIndex]
        guard root.indentLevel < TaskItem.maxIndentLevel else { return nil }
        let afterIndex = TaskOutline.subtreeRange(display, at: rootIndex).upperBound - 1
        return ActiveAdd(afterIndex: afterIndex, level: root.indentLevel + 1, parentID: root.id)
    }

    private func row(_ task: TaskItem, isDropParent: Bool) -> some View {
        let isHead = drag.taskID == task.id
        // Mid-drag the dragged row stays mounted — invisible, one line tall, under its placeholder. It
        // received the drag's mouse-down, and removing it would silently stop the drag's events.
        return taskRow(task)
            .background {
                if isDropParent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accent.opacity(0.13))
                        .padding(.leading, CGFloat(task.indentLevel) * NoteLayout.indentStep)
                        .padding(.horizontal, -6)
                }
            }
            .opacity(isHead ? 0 : 1)
            .frame(height: isHead ? LiftedRow.height - 2 : nil, alignment: .top)
            .overlay {
                if isHead {
                    DropPlaceholder(task: task, carried: drag.block.count - 1, level: drag.level, theme: theme)
                }
            }
            .padding(.horizontal, NoteLayout.rowInset)
            .padding(.vertical, 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowFrame.Key.self,
                        value: [RowFrame(id: task.id, frame: geo.frame(in: .named(Self.listSpace)))]
                    )
                }
            )
            // Reorder is paused while completed are auto-sorted to the bottom (it would fight the sort), and on a
            // row whose image is being pointed at or cropped (so its buttons / crop handles never drag the task).
            // `.subviews` disables only this drag gesture, leaving the checkbox / editor / image usable.
            .gesture(
                reorderGesture(for: task),
                including: controller.isReorderable && imageInteractionTaskID != task.id ? .all : .subviews
            )
    }

    private func taskRow(_ task: TaskItem) -> some View {
        TaskRowView(
            task: task,
            theme: theme,
            autoEdit: task.id == addingRowID,
            canReorder: controller.isReorderable,
            onToggle: { controller.toggle(task) },
            onCommit: { controller.commitText(task, $0) },
            onDelete: { controller.delete(task) },
            onIndent: { controller.indent(task) },
            onOutdent: { controller.outdent(task) },
            onSubmit: { continueAdding(after: task) },
            onHoverChanged: { hovering in
                if hovering { withAnimation(.easeInOut(duration: 0.12)) { activeSectionID = sectionRootID(of: task) } }
            },
            image: controller.imageCrops[task.id].map { crop in
                TaskImageView(
                    image: controller.thumbnails[task.id], crop: crop, theme: theme,
                    onCrop: { controller.setCrop($0, for: task) },
                    onOpen: { controller.openImage(task) },
                    onRemove: { controller.removeImage(from: task) },
                    onInteractionChange: { active in setImageInteraction(task.id, active) }
                )
            },
            onPasteImage: { controller.attachImage($0, to: task) }
        )
    }
}

/// Where the "Add subtask" affordance sits: after row `afterIndex`, indented to `level`, under `parentID`.
private struct ActiveAdd {
    let afterIndex: Int
    let level: Int
    let parentID: TaskItem.ID
}

// MARK: - Reorder drag

extension NoteView {
    /// Records whether `id`'s image is being pointed at or cropped; that row's reorder drag pauses meanwhile.
    private func setImageInteraction(_ id: TaskItem.ID, _ active: Bool) {
        if active {
            imageInteractionTaskID = id
        } else if imageInteractionTaskID == id {
            imageInteractionTaskID = nil
        }
    }

    private func reorderGesture(for task: TaskItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .updating($reorderGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if drag.taskID == nil { beginDrag(task, from: value.startLocation) }
                drag.location = value.location   // read only by the lifted row: no list re-render
                retarget()
            }
            .onEnded { _ in endDrag() }
    }

    /// Lifts `task` and its subtree; its row becomes the placeholder, still in its own slot.
    private func beginDrag(_ task: TaskItem, from start: CGPoint) {
        let display = controller.displayedTasks
        guard let index = display.firstIndex(where: { $0.id == task.id }) else { return }
        let range = TaskOutline.subtreeRange(display, at: index)
        withAnimation(.snappy(duration: 0.16)) {
            drag.startFrame = rowFrames.first { $0.id == task.id }?.frame ?? .zero
            drag.startLocation = start
            drag.location = start
            drag.blockRange = range
            drag.slot = range.lowerBound
            drag.level = task.indentLevel
            drag.block = Array(display[range])
        }
    }

    /// Re-derives the drop slot and level from the pointer, writing only when either changes — so the
    /// list re-renders a few times per drag, not every frame.
    private func retarget() {
        guard let head = drag.block.first else { return }
        let blockIDs = Set(drag.block.map(\.id))
        let rest = dragRest
        // Compare against the rows' on-screen midpoints with the placeholder's gap open, so the slot
        // only moves once the lifted row has fully crossed a neighbour — no flicker at the boundary.
        let center = drag.liftedTop + LiftedRow.height / 2
        let slot = min(rowFrames.filter { !blockIDs.contains($0.id) && $0.frame.midY < center }.count, rest.count)
        let depth = (drag.block.map(\.indentLevel).max() ?? head.indentLevel) - head.indentLevel
        let allowed = TaskOutline.dropLevels(rest, slot: slot, blockDepth: depth)
        let wanted = head.indentLevel + TaskOutline.levelSteps(
            forDrag: drag.location.x - drag.startLocation.x, step: NoteLayout.indentStep
        )
        let level = min(max(wanted, allowed.lowerBound), allowed.upperBound)
        guard slot != drag.slot || level != drag.level else { return }
        withAnimation(.snappy(duration: 0.16)) {
            drag.slot = slot
            drag.level = level
        }
    }

    private func endDrag() {
        guard let id = drag.taskID else { return }
        // The slot indexes the list without the block; map it to a displayed, then a true `tasks` index.
        let index = TaskOutline.insertionIndex(forSlot: drag.slot, removing: drag.blockRange)
        let level = drag.level
        withAnimation(.snappy(duration: 0.18)) {
            controller.moveTask(
                id: id, toInsertionIndex: controller.trueInsertionIndex(forDisplayedIndex: index), targetLevel: level
            )
            drag.block = []
        }
    }

    /// Abandons an in-flight drag, leaving every task where it was.
    private func cancelDrag() {
        guard isDragging else { return }
        withAnimation(.snappy(duration: 0.18)) { drag.block = [] }
    }

    /// The displayed rows minus the dragged block — what a drop slot indexes into.
    private var dragRest: [TaskItem] {
        let ids = Set(drag.block.map(\.id))
        return controller.displayedTasks.filter { !ids.contains($0.id) }
    }

    /// The rows shown mid-drag: the rest, with the dragged head standing in as the placeholder at the slot.
    private var dragRows: [TaskItem] {
        guard let head = drag.block.first else { return controller.displayedTasks }
        var rows = dragRest
        rows.insert(head, at: min(drag.slot, rows.count))
        return rows
    }

    /// The task that will receive the drop, tinted while dragging; nil for a top-level drop.
    private var dropParentID: TaskItem.ID? {
        guard isDragging else { return nil }
        let rest = dragRest
        return TaskOutline.dropParentIndex(rest, slot: drag.slot, level: drag.level).map { rest[$0].id }
    }

    /// Mid-drag: the lifted row under the pointer, and the elbow from the receiving parent to the placeholder.
    @ViewBuilder
    private func dragOverlay(parentID: TaskItem.ID?) -> some View {
        if let head = drag.block.first {
            ZStack(alignment: .topLeading) {
                if let thread = dropThread(parentID: parentID) {
                    thread
                        .stroke(theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .animation(.snappy(duration: 0.16), value: thread)
                }
                LiftedRow(drag: drag, task: head, theme: theme)
            }
            .allowsHitTesting(false)
        }
    }

    /// The elbow from the parent's checkbox, down the indent gutter, into the placeholder's leading edge.
    private func dropThread(parentID: TaskItem.ID?) -> DropThread? {
        guard let parentID, let headID = drag.taskID,
              let parent = rowFrames.first(where: { $0.id == parentID })?.frame,
              let slot = rowFrames.first(where: { $0.id == headID })?.frame,
              let level = controller.displayedTasks.first(where: { $0.id == parentID })?.indentLevel
        else { return nil }
        return DropThread(
            x: NoteLayout.rowInset + CGFloat(level) * NoteLayout.indentStep + 8,   // checkbox centre
            top: parent.minY + 20,                                                  // just under it
            bottom: slot.midY,
            endX: NoteLayout.rowInset - 6 + CGFloat(drag.level) * NoteLayout.indentStep
        )
    }
}

/// A task row's frame in list coordinates, reported up so a drag knows where the rows sit.
private struct RowFrame: Equatable {
    let id: UUID
    let frame: CGRect

    struct Key: PreferenceKey {
        static let defaultValue: [RowFrame] = []
        static func reduce(value: inout [RowFrame], nextValue: () -> [RowFrame]) {
            value.append(contentsOf: nextValue())
        }
    }
}

/// The "Add subtask" affordance, revealed at the bottom of a hovered heading's group. It's a ghost of
/// the task a click will create — a hollow plus where the checkbox will sit, at the subtask's indent —
/// so where the new row lands reads at a glance. A quieter echo of the bottom "Add a task…" bar.
private struct AddSubtaskRow: View {
    let theme: NoteTheme
    let level: Int
    let onActivate: () -> Void
    let onHoverChanged: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(theme.accent.opacity(hovering ? 1 : 0.65))
                Text("Add subtask")
                    .font(.callout)
                    .foregroundStyle(hovering ? theme.task : theme.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.leading, NoteLayout.rowInset + CGFloat(level) * NoteLayout.indentStep)
        .padding(.trailing, 16)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.1)) { hovering = h }
            onHoverChanged(h)
        }
        .help("Add a subtask")
        .transition(.opacity)
    }
}
