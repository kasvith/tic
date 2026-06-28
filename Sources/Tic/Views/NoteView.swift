import AppKit
import SwiftUI

/// Shared layout constants so the SwiftUI collapsed bar and the AppKit window resize agree.
enum NoteLayout {
    /// Height of a rolled-up note (shows only its title bar).
    static let collapsedHeight: CGFloat = 44
    /// Horizontal inset added per nesting level, so subtasks step to the right of their parent.
    static let indentStep: CGFloat = 20
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
/// the dragged row follows the cursor immediately, the other rows stay put, a drop-indicator
/// line shows the landing spot, and the move commits once on release. (On macOS scrolling is the
/// wheel/trackpad, so a click-drag here doesn't fight the ScrollView.)
struct NoteView: View {
    @Bindable var controller: NoteController

    @State private var titleText: String
    @State private var newTaskText: String = ""
    @State private var newTaskLevel: Int = 0
    @State private var revealed = false
    @State private var draggingTaskID: TaskItem.ID?
    @State private var dragOffsetY: CGFloat = 0
    @State private var dropIndex: Int?
    @State private var dropLevel: Int = 0
    @State private var dragStartLevel: Int = 0
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
    @State private var quickAddFocused = false   // show the quick-add's newline hint only while typing
    @FocusState private var titleFocused: Bool

    private static let listSpace = "tic.tasklist"

    init(controller: NoteController) {
        self.controller = controller
        _titleText = State(initialValue: controller.note.title)
    }

    private var note: Note { controller.note }
    private var isDragging: Bool { draggingTaskID != nil }

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
            quickAdd
        }
    }

    // MARK: - Task list

    private var taskList: some View {
        let add = activeAdd
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.tasks.enumerated()), id: \.element.id) { index, task in
                        if isDragging, dropIndex == index { dropIndicator(level: dropLevel) }
                        row(task)
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
                    if isDragging, dropIndex == controller.tasks.count { dropIndicator(level: dropLevel) }
                }
                .padding(.top, 4)
                .padding(.bottom, 12)   // breathing room so the last row never crowds the quick-add bar
                .coordinateSpace(.named(Self.listSpace))
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
            .overlay(alignment: .top) {
                if controller.tasks.isEmpty {
                    Text("No tasks yet — add one below")
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
        guard var i = controller.tasks.firstIndex(where: { $0.id == task.id }) else { return nil }
        while i > 0, controller.tasks[i].indentLevel > 0 { i -= 1 }
        return controller.tasks[i].id
    }

    /// Where to show the "Add subtask" affordance: after the last row of the hovered heading's group,
    /// indented one level under the heading. Hidden during a drag or while a rapid-add run is already
    /// in progress (Return drives that, so the affordance would only be noise).
    private var activeAdd: (afterIndex: Int, level: Int, parentID: TaskItem.ID)? {
        guard !isDragging, addingRowID == nil,
              let sectionID = activeSectionID,
              let rootIndex = controller.tasks.firstIndex(where: { $0.id == sectionID }) else { return nil }
        let root = controller.tasks[rootIndex]
        guard root.indentLevel < TaskItem.maxIndentLevel else { return nil }
        let afterIndex = TaskOutline.subtreeRange(controller.tasks, at: rootIndex).upperBound - 1
        return (afterIndex, root.indentLevel + 1, root.id)
    }

    private func row(_ task: TaskItem) -> some View {
        let dragging = draggingTaskID == task.id
        return TaskRowView(
            task: task,
            theme: theme,
            autoEdit: task.id == addingRowID,
            onToggle: { controller.toggle(task) },
            onCommit: { controller.commitText(task, $0) },
            onDelete: { controller.delete(task) },
            onIndent: { controller.indent(task) },
            onOutdent: { controller.outdent(task) },
            onSubmit: { continueAdding(after: task) },
            onHoverChanged: { hovering in
                if hovering { withAnimation(.easeInOut(duration: 0.12)) { activeSectionID = sectionRootID(of: task) } }
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFrame.Key.self,
                    value: [RowFrame(id: task.id, midY: geo.frame(in: .named(Self.listSpace)).midY)]
                )
            }
        )
        // Follow the cursor vertically; shift horizontally to preview the target nesting level.
        .offset(
            x: dragging ? CGFloat(dropLevel - dragStartLevel) * NoteLayout.indentStep : 0,
            y: dragging ? dragOffsetY : 0
        )
        .scaleEffect(dragging ? 1.02 : 1, anchor: .center)
        .opacity(dragging ? 0.95 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: dragging ? 5 : 0, y: 2)
        .zIndex(dragging ? 1 : 0)
        .gesture(reorderGesture(for: task))
    }

    private func reorderGesture(for task: TaskItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if draggingTaskID != task.id {
                    draggingTaskID = task.id
                    dragStartLevel = task.indentLevel   // re-nest is measured from where it started
                }
                dragOffsetY = value.translation.height
                let index = insertionIndex(at: value.location.y)
                dropIndex = index
                dropLevel = targetLevel(forDropIndex: index, dragWidth: value.translation.width)
            }
            .onEnded { _ in
                let id = draggingTaskID
                let index = dropIndex
                let level = dropLevel
                withAnimation(.snappy(duration: 0.18)) {
                    if let id, let index {
                        controller.moveTask(id: id, toInsertionIndex: index, targetLevel: level)
                    }
                    draggingTaskID = nil
                    dragOffsetY = 0
                    dropIndex = nil
                }
            }
    }

    /// Number of rows whose midpoint sits above `y` = the index a drop there would insert at.
    private func insertionIndex(at y: CGFloat) -> Int {
        rowFrames.filter { $0.midY < y }.count
    }

    /// The nesting level a drop would land at: the dragged row's starting depth plus how far right
    /// it's been dragged (one step per `indentStep`), clamped to what the row above the drop allows
    /// (you can't be deeper than one level below your would-be parent, capped at 3 levels).
    private func targetLevel(forDropIndex index: Int, dragWidth: CGFloat) -> Int {
        let above = index - 1
        let maxLevel = (above >= 0 && above < controller.tasks.count)
            ? min(TaskItem.maxIndentLevel, controller.tasks[above].indentLevel + 1)
            : 0
        let desired = dragStartLevel + Int((dragWidth / NoteLayout.indentStep).rounded())
        return min(max(desired, 0), maxLevel)
    }

    private func dropIndicator(level: Int) -> some View {
        Capsule()
            .fill(theme.accent)
            .frame(height: 2)
            .padding(.leading, 12 + CGFloat(level) * NoteLayout.indentStep)
            .padding(.trailing, 12)
    }

    // MARK: - Quick add

    private var quickAdd: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent.opacity(0.7))

            // Multiline like the rows: Return adds the task, Shift/Option-Return inserts a newline,
            // and Shift-Tab / Ctrl-Shift-Tab pre-sets the nesting level of the task being typed.
            PlainTextEditor(
                text: $newTaskText,
                textColor: theme.task,
                onCommit: { submitNewTask() },
                onIndent: { adjustNewTaskLevel(by: 1) },
                onOutdent: { adjustNewTaskLevel(by: -1) },
                onFocusChange: { focused in
                    withAnimation(.easeInOut(duration: 0.15)) { quickAddFocused = focused }
                }
            )
            .overlay(alignment: .topLeading) {
                if newTaskText.isEmpty {
                    Text(effectiveNewTaskLevel > 0 ? "Add a subtask…" : "Add a task…")
                        .foregroundStyle(theme.secondary)
                        .padding(.top, PlainTextEditor.topInset)   // align with the editor's text inset
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)   // fill the bar so text wraps at the note width
            .editorFirstBaseline()

            // Minimal hint: the newline shortcut, shown only while the quick-add has focus.
            if quickAddFocused {
                ShortcutHint(glyphs: "⇧⏎", label: "line", theme: theme)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 16 + CGFloat(effectiveNewTaskLevel) * NoteLayout.indentStep)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .background(theme.accent.opacity(theme.isGlass ? 0.04 : 0.08))
        .animation(.snappy(duration: 0.15), value: effectiveNewTaskLevel)
    }

    /// The pending indent clamped to what the current last row allows — i.e. the level a new task
    /// will *actually* land at. Computed from the live task list so the field's indent and
    /// placeholder stay truthful even after the list changes by delete / outdent / reorder.
    private var effectiveNewTaskLevel: Int {
        let maxAllowed = controller.tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        return min(max(newTaskLevel, 0), maxAllowed)
    }

    /// Adds the pending task (if any) at the effective indent level and clears the field. Called on
    /// Return and on focus loss (the editor keeps focus after Return, so rapid entry still works).
    private func submitNewTask() {
        guard !newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.addTask(newTaskText, level: effectiveNewTaskLevel)
        newTaskText = ""
    }

    /// Nudges the pending new-task level, clamped to what the last existing row allows so the
    /// quick-add indent can never promise a depth the outline wouldn't accept.
    private func adjustNewTaskLevel(by delta: Int) {
        let maxAllowed = controller.tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        newTaskLevel = min(max(effectiveNewTaskLevel + delta, 0), maxAllowed)
    }
}

/// The vertical midpoint of a task row, reported up so the drag can compute where a dragged row
/// would land — without reshuffling the list during the drag.
private struct RowFrame: Equatable {
    let id: UUID
    let midY: CGFloat

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
        .padding(.leading, 12 + CGFloat(level) * NoteLayout.indentStep)
        .padding(.trailing, 16)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.1)) { hovering = h }
            onHoverChanged(h)
        }
        .help("Add a subtask")
        .transition(.opacity)
    }
}
