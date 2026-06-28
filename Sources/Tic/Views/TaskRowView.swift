import SwiftUI

/// A single checklist row. Shows the task as rendered inline **Markdown** (bold, *italic*,
/// `code`, ~~strike~~, [links]) across as many lines as it has; tap the text to edit the raw
/// source in a plain, growing text box. While editing, **Return** commits and **Shift-Return**
/// (or Option-Return) inserts a newline; **Shift-Tab** nests the task one level deeper and
/// **Ctrl-Shift-Tab** promotes it back out. Editing commits on Return or when focus leaves.
/// Hover reveals a ✕ delete button; the "Add subtask" affordance lives at the bottom of the hovered
/// heading's group and is rendered by `NoteView` (this row just reports its hover state up).
struct TaskRowView: View {
    let task: TaskItem
    let theme: NoteTheme
    /// True while this row is the active rapid-add target: it begins editing as soon as it appears —
    /// and again if the list scrolls and the LazyVStack recreates it — so a freshly-added subtask
    /// keeps the keyboard and typing flows uninterrupted. The parent clears it when the run ends.
    let autoEdit: Bool
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

    @State private var draft: String
    @State private var editing = false
    @State private var hovering = false
    // Memoises the parsed Markdown so it isn't re-parsed on every re-render (e.g. each frame of a
    // drag), which otherwise makes reordering feel laggy.
    @State private var renderCache = MarkdownRenderCache()

    init(
        task: TaskItem,
        theme: NoteTheme,
        autoEdit: Bool = false,
        onToggle: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onIndent: @escaping () -> Void,
        onOutdent: @escaping () -> Void,
        onSubmit: @escaping () -> Void = {},
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.task = task
        self.theme = theme
        self.autoEdit = autoEdit
        self.onToggle = onToggle
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onIndent = onIndent
        self.onOutdent = onOutdent
        self.onSubmit = onSubmit
        self.onHoverChanged = onHoverChanged
        _draft = State(initialValue: task.text)
    }

    private var baseColor: Color { task.isDone ? theme.completed : theme.task }
    private var canNestDeeper: Bool { task.indentLevel < TaskItem.maxIndentLevel }

    var body: some View {
        taskRow
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.12)) { hovering = isHovering }
                onHoverChanged(isHovering)
            }
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
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(task.indentLevel) * NoteLayout.indentStep)
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
                onOutdent: onOutdent
            )
            .editorFirstBaseline()
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
