import SwiftUI

/// The bar along the bottom of a note that adds a task: ⊕ plus a multiline editor, with any image pasted
/// while nothing is being edited waiting above it until Return. Owns the typed text and pending indent.
struct QuickAddBar: View {
    let controller: NoteController
    let theme: NoteTheme

    @State private var newTaskText: String = ""
    @State private var newTaskLevel: Int = 0
    @State private var quickAddFocused = false   // show the newline hint only while typing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.pendingImage != nil { pendingImageChip }
            quickAddField
        }
        .padding(.leading, 16 + CGFloat(effectiveNewTaskLevel) * NoteLayout.indentStep)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .background(theme.accent.opacity(theme.isGlass ? 0.04 : 0.08))
        .animation(.snappy(duration: 0.15), value: effectiveNewTaskLevel)
    }

    /// An image pasted into the quick-add, waiting for Return: a small thumbnail, lined up with the text,
    /// with a ✕ to discard it.
    private var pendingImageChip: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = controller.pendingThumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.accent.opacity(0.15))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: 160, maxHeight: 44, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Button { controller.discardPendingImage() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("Discard image")
        }
        .padding(.leading, 24)   // the ⊕ icon + spacing, so the chip sits over the text
        .transition(.opacity)
    }

    /// The ⊕ and editor line of the quick-add bar.
    private var quickAddField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent.opacity(0.7))

            // Multiline like the rows: Return adds the task, Shift/Option-Return inserts a newline,
            // and Shift-Tab / Ctrl-Shift-Tab pre-sets the nesting level of the task being typed.
            PlainTextEditor(
                text: $newTaskText,
                textColor: theme.task,
                // A docked note's list appears only when it opens (its tab draws nothing else), so this field is new
                // each time and takes the keyboard: click the tab, type, Return.
                autoFocus: controller.isDocked,
                focusRequest: controller.quickAddFocusRequest,
                // Focus loss adds typed text too — but not while an image is waiting: that stays put until
                // Return (`onSubmit`), so clicking away can never create an image task by accident.
                onCommit: { if controller.pendingImage == nil { submitNewTask() } },
                onSubmit: { submitNewTask() },
                onIndent: { adjustNewTaskLevel(by: 1) },
                onOutdent: { adjustNewTaskLevel(by: -1) },
                onFocusChange: { focused in
                    withAnimation(.easeInOut(duration: 0.15)) { quickAddFocused = focused }
                },
                onPasteImage: { controller.stageImage($0) }
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
    }

    /// The pending indent clamped to what the current last row allows — i.e. the level a new task
    /// will *actually* land at. Computed from the live task list so the field's indent and
    /// placeholder stay truthful even after the list changes by delete / outdent / reorder.
    private var effectiveNewTaskLevel: Int {
        let maxAllowed = controller.tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        return min(max(newTaskLevel, 0), maxAllowed)
    }

    /// Adds the pending task (if any) — with any image waiting in the field — at the effective indent
    /// level and clears the field. Called on Return, and on focus loss while no image is waiting (the
    /// editor keeps focus after Return, so rapid entry still works).
    private func submitNewTask() {
        let hasText = !newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || controller.pendingImage != nil else { return }
        controller.addTaskFromQuickAdd(newTaskText, level: effectiveNewTaskLevel)
        newTaskText = ""
    }

    /// Nudges the pending new-task level, clamped to what the last existing row allows so the
    /// quick-add indent can never promise a depth the outline wouldn't accept.
    private func adjustNewTaskLevel(by delta: Int) {
        let maxAllowed = controller.tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        newTaskLevel = min(max(effectiveNewTaskLevel + delta, 0), maxAllowed)
    }
}
