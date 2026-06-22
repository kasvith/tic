import SwiftUI

/// Shared layout constants so the SwiftUI collapsed bar and the AppKit window resize agree.
enum NoteLayout {
    /// Height of a rolled-up note (shows only its title bar).
    static let collapsedHeight: CGFloat = 44
}

/// The contents of a single sticky note: a hover-reveal header, a reorderable checklist, and a
/// quick-add field — or, when rolled up, just a compact title bar. State and persistence are
/// owned by `NoteController`.
///
/// The task list uses `ScrollView { LazyVStack }` rather than `List` on purpose — a macOS `List`
/// is NSTableView-backed and draws a dark "emphasized" selection highlight behind a focused row,
/// which looked like an ugly black box when editing. A plain stack has no selection chrome.
///
/// Reorder uses a direct `DragGesture` (not the system `.onDrag`, which has a sluggish pickup):
/// the dragged row follows the cursor immediately, the other rows stay put, a drop-indicator
/// line shows the landing spot, and the move commits once on release. (On macOS scrolling is the
/// wheel/trackpad, so a click-drag here doesn't fight the ScrollView.)
struct NoteView: View {
    @Bindable var controller: NoteController

    @State private var titleText: String
    @State private var newTaskText: String = ""
    @State private var revealed = false
    @State private var draggingTaskID: TaskItem.ID?
    @State private var dragOffsetY: CGFloat = 0
    @State private var dropIndex: Int?
    @State private var rowFrames: [RowFrame] = []
    @FocusState private var titleFocused: Bool
    @FocusState private var quickAddFocused: Bool

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
            Text(note.title.isEmpty ? "Untitled" : note.title)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(controller.tasks.enumerated()), id: \.element.id) { index, task in
                    if isDragging, dropIndex == index { dropIndicator }
                    row(task)
                }
                if isDragging, dropIndex == controller.tasks.count { dropIndicator }
            }
            .padding(.vertical, 4)
            .coordinateSpace(.named(Self.listSpace))
            .onPreferenceChange(RowFrame.Key.self) { rowFrames = $0 }
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            if controller.tasks.isEmpty {
                Text("No tasks yet — add one below")
                    .font(.callout)
                    .foregroundStyle(theme.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        let dragging = draggingTaskID == task.id
        return TaskRowView(
            task: task,
            theme: theme,
            onToggle: { controller.toggle(task) },
            onCommit: { controller.commitText(task, $0) },
            onDelete: { controller.delete(task) }
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
        .offset(y: dragging ? dragOffsetY : 0)
        .scaleEffect(dragging ? 1.02 : 1, anchor: .center)
        .opacity(dragging ? 0.95 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: dragging ? 5 : 0, y: 2)
        .zIndex(dragging ? 1 : 0)
        .gesture(reorderGesture(for: task))
    }

    private func reorderGesture(for task: TaskItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if draggingTaskID != task.id { draggingTaskID = task.id }
                dragOffsetY = value.translation.height
                dropIndex = insertionIndex(at: value.location.y)
            }
            .onEnded { _ in
                let id = draggingTaskID
                let index = dropIndex
                withAnimation(.snappy(duration: 0.18)) {
                    if let id, let index { controller.moveTask(id: id, toInsertionIndex: index) }
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

    private var dropIndicator: some View {
        Capsule()
            .fill(theme.accent)
            .frame(height: 2)
            .padding(.horizontal, 12)
    }

    // MARK: - Quick add

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent.opacity(0.7))

            TextField("Add a task…", text: $newTaskText)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.task)
                .focused($quickAddFocused)
                .onSubmit {
                    controller.addTask(newTaskText)
                    newTaskText = ""
                    quickAddFocused = true   // keep focus for rapid entry
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.accent.opacity(theme.isGlass ? 0.04 : 0.08))
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
