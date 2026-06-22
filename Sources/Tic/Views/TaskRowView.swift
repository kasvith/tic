import SwiftUI

/// A single checklist row. Shows the task as rendered inline **Markdown** (bold, *italic*,
/// `code`, ~~strike~~, [links]); tap the text to edit the raw source, which commits on Return or
/// when focus leaves. A hover-revealed ✕ deletes the row.
struct TaskRowView: View {
    let task: TaskItem
    let theme: NoteTheme
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(
        task: TaskItem,
        theme: NoteTheme,
        onToggle: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.task = task
        self.theme = theme
        self.onToggle = onToggle
        self.onCommit = onCommit
        self.onDelete = onDelete
        _draft = State(initialValue: task.text)
    }

    private var baseColor: Color { task.isDone ? theme.completed : theme.task }

    var body: some View {
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

            if hovering && !editing {
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .foregroundStyle(baseColor)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        } else {
            Text(rendered)
                .strikethrough(task.isDone, color: theme.completed.opacity(0.7))
                .opacity(task.isDone ? 0.85 : 1)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    /// Task text parsed as inline Markdown, tinted to the theme. Falls back to plain text if the
    /// Markdown can't be parsed.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var attributed = (try? AttributedString(markdown: task.text, options: options))
            ?? AttributedString(task.text)
        // Tint normal text; leave links their default accent colour so they read as links.
        for run in attributed.runs where run.link == nil {
            attributed[run.range].foregroundColor = baseColor
        }
        return attributed
    }

    private func beginEditing() {
        draft = task.text
        editing = true
        // Focus once the TextField has been inserted into the hierarchy.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        editing = false
        onCommit(draft)
    }
}
