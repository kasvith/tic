import SwiftUI

/// A single checklist row. Shows the task as rendered inline **Markdown** (bold, *italic*,
/// `code`, ~~strike~~, [links]) across as many lines as it has; tap the text to edit the raw
/// source in a plain, growing text box. While editing, **Return** commits and **Shift-Return**
/// (or Option-Return) inserts a newline; **Shift-Tab** nests the task one level deeper and
/// **Ctrl-Shift-Tab** promotes it back out. Editing commits on Return or when focus leaves.
/// Hover reveals a ✕ delete button and, when the list is reorderable, a drag grip left of the checkbox;
/// the "Add subtask" affordance lives at the bottom of the hovered
/// heading's group and is rendered by `NoteView` (this row just reports its hover state up).
struct TaskRowView: View {
    let task: TaskItem
    let theme: NoteTheme
    /// True while this row is the active rapid-add target: it begins editing as soon as it appears —
    /// and again if the list scrolls and the LazyVStack recreates it — so a freshly-added subtask
    /// keeps the keyboard and typing flows uninterrupted. The parent clears it when the run ends.
    let autoEdit: Bool
    /// Shows the drag grip on hover (off while the list auto-sorts and reordering is paused).
    let canReorder: Bool
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    /// Fired when the user commits this row with Return (not Esc / focus loss). Used to chain the
    /// next subtask in the rapid-add flow.
    let onSubmit: () -> Void
    /// Reports hover enter/leave up to the list, which uses it to reveal the "Add subtask" affordance
    /// at the bottom of the hovered heading's group.
    let onHoverChanged: (Bool) -> Void
    /// The task's pasted image (built by `NoteView`), shown under the text; nil when it has none.
    let image: TaskImageView?
    /// ⌘V of an image while this row is being edited attaches it to the task.
    let onPasteImage: (Data) -> Void

    @State private var draft: String
    @State private var editing = false
    @State private var hovering = false
    // Memoises the parsed Markdown so it isn't re-parsed on every re-render (e.g. each frame of a
    // drag), which otherwise makes reordering feel laggy.
    @State private var renderCache = MarkdownRenderCache()

    /// Where the text column starts — the 16pt checkbox glyph plus the row's spacing — so the image lines up.
    private static let textInset: CGFloat = 24
    /// How far the hover region reaches left of the checkbox, into the gutter where the grip sits.
    private static let gripGutter: CGFloat = 9

    init(
        task: TaskItem,
        theme: NoteTheme,
        autoEdit: Bool = false,
        canReorder: Bool = false,
        onToggle: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onIndent: @escaping () -> Void,
        onOutdent: @escaping () -> Void,
        onSubmit: @escaping () -> Void = {},
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        image: TaskImageView? = nil,
        onPasteImage: @escaping (Data) -> Void = { _ in }
    ) {
        self.task = task
        self.theme = theme
        self.autoEdit = autoEdit
        self.canReorder = canReorder
        self.onToggle = onToggle
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onIndent = onIndent
        self.onOutdent = onOutdent
        self.onSubmit = onSubmit
        self.onHoverChanged = onHoverChanged
        self.image = image
        self.onPasteImage = onPasteImage
        _draft = State(initialValue: task.text)
    }

    private var baseColor: Color { task.isDone ? theme.completed : theme.task }
    private var canNestDeeper: Bool { task.indentLevel < TaskItem.maxIndentLevel }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hover is tracked on the text line only. Over an image it would reveal the ✕ and the section's
            // "Add subtask" row, and either shifts the layout under a pointer resting on a tall picture.
            taskRow
                // Reach into the gutter so pointing at the grip doesn't end the hover that shows it.
                .padding(.leading, Self.gripGutter)
                .overlay(alignment: .topLeading) {
                    if canReorder && hovering && !editing {
                        GripDots().fill(theme.secondary.opacity(0.55)).frame(width: 6, height: 10).padding(.top, 4)
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.12)) { hovering = isHovering }
                    onHoverChanged(isHovering)
                }
                .padding(.leading, -Self.gripGutter)
            // Below the text line's HStack, so the ✕ / nest hint appearing can't narrow a fill-width image —
            // which would shorten the row under the pointer and make the hover flicker on and off.
            image
                .opacity(task.isDone ? 0.6 : 1)
                .padding(.leading, Self.textInset)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(task.indentLevel) * NoteLayout.indentStep)
        .contentShape(Rectangle())
            // Begin editing whenever this becomes (or re-becomes, after a scroll recreates the row)
            // the active add target. `beginEditing` is a no-op once already editing, so a plain
            // re-render won't disturb an in-progress edit — only a fresh appearance re-triggers it.
            .onAppear { if autoEdit { beginEditing() } }
            .onChange(of: autoEdit) { _, shouldEdit in
                if shouldEdit { beginEditing() }
            }
    }

    private var taskRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(task.isDone ? theme.checkbox : theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if editing {
                // Minimal hint: the nest shortcut, shown only while this row is being edited.
                if canNestDeeper {
                    ShortcutHint(glyphs: "⇧⇥", label: "nest", theme: theme)
                }
            } else if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if editing {
            // A plain, vertically-growing AppKit text box: Return commits, Shift/Option-Return adds
            // a line, Shift-Tab nests, Ctrl-Shift-Tab promotes. Commits on Return / Esc / focus loss.
            PlainTextEditor(
                text: $draft,
                textColor: baseColor,
                autoFocus: true,
                onCommit: { commit() },
                onSubmit: onSubmit,
                onIndent: onIndent,
                onOutdent: onOutdent,
                onPasteImage: onPasteImage
            )
            .editorFirstBaseline()
        } else if task.text.isEmpty {
            // An image-only task: an empty line (a hint on hover) keeps the row's height steady and is
            // where you click to add text.
            Text("Add text…")
                .foregroundStyle(theme.secondary)
                .opacity(hovering ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        } else {
            Text(renderCache.rendered(text: task.text, color: baseColor))
                .strikethrough(task.isDone, color: theme.completed.opacity(0.7))
                .opacity(task.isDone ? 0.85 : 1)
                .fixedSize(horizontal: false, vertical: true)   // wrap + grow, don't truncate
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private func beginEditing() {
        guard !editing else { return }   // already editing: keep the in-progress draft, don't reset it
        draft = task.text
        editing = true   // PlainTextEditor grabs focus itself (autoFocus).
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onCommit(draft)
    }
}

/// The six-dot drag grip: left of a task's checkbox on hover, and on the lifted row mid-drag.
struct GripDots: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for column in 0..<2 {
            for row in 0..<3 {
                path.addEllipse(in: CGRect(x: CGFloat(column) * 3.6, y: CGFloat(row) * 3.8, width: 2.2, height: 2.2))
            }
        }
        return path
    }
}

/// Caches a task's text rendered as tinted inline Markdown, re-parsing only when the text or colour
/// actually changes. Held by reference in a row's `@State` so the (relatively costly) Markdown parse
/// doesn't run on every SwiftUI body re-evaluation — notably the many re-renders during a drag.
@MainActor
final class MarkdownRenderCache {
    private var cachedText: String?
    private var cachedColor: Color?
    private var value = AttributedString()

    func rendered(text: String, color: Color) -> AttributedString {
        if text == cachedText, color == cachedColor { return value }
        value = Self.parse(text, color: color)
        cachedText = text
        cachedColor = color
        return value
    }

    /// Parses each line as inline Markdown (bold/italic/`code`/~~strike~~/links), tinting normal
    /// text to `color` and leaving links their accent. Newlines are preserved so a multiline task
    /// renders across multiple lines; each line is parsed alone so a break never merges two lines.
    private static func parse(_ text: String, color: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var result = AttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var attributed = (try? AttributedString(markdown: String(line), options: options))
                ?? AttributedString(String(line))
            for run in attributed.runs where run.link == nil {
                attributed[run.range].foregroundColor = color
            }
            result.append(attributed)
        }
        return result
    }
}
