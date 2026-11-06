import SwiftUI

/// A sticky note's top row — the editable title, with roll-up / pin / close and a ⋯ options popover fading
/// in on the right while the pointer is on the note (`isRevealed`, driven by `NoteView`'s hover) — over an
/// accent rule. Rolled up,
/// the bar *is* this row (minus the rule, plus the open-task count), so rolling is a pure window shade.
struct NoteHeaderView: View {
    @Bindable var controller: NoteController
    let theme: NoteTheme
    let isRevealed: Bool
    /// Drawn as the rolled-up bar: the title can't be edited (a click drags, a double-click expands), and
    /// hover shows only expand / pin / close.
    var isRolledUp = false

    @Binding var titleText: String
    @FocusState.Binding var titleFocused: Bool

    @State private var showOptions = false
    @State private var showClearConfirm = false
    @State private var editingTitle = false

    private var note: Note { controller.note }

    /// Controls stay up while the options popover is open: it's a separate window, so the pointer leaves
    /// the note to reach it.
    private var showsControls: Bool { isRevealed || showOptions || showClearConfirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                titleField
                Spacer(minLength: 0)
                if isRolledUp { remainingCount }
                if showsControls { controls.transition(.opacity) }
            }
            .frame(height: NoteLayout.collapsedHeight)   // the rolled-up bar is exactly this row

            if !isRolledUp {
                Rectangle()
                    .fill(theme.accent.opacity(0.35))
                    .frame(height: 1)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        // The header is the window's drag handle; double-clicking its chrome rolls the note up or down.
        .background(WindowMoveArea { controller.toggleCollapsed() })
        .help(isRolledUp ? "Drag to move · double-click to expand" : "")
        .onChange(of: titleFocused) { _, focused in
            guard !focused else { return }
            commitTitle()
            editingTitle = false
        }
        .task(id: controller.renameRequest) {   // also runs on appear, for a list that opens renaming
            if controller.renameRequest > 0, !isRolledUp { editingTitle = true }
        }
    }

    /// Plain text that's part of the drag handle (a press drags, a double-click rolls up — in the window's
    /// hidden title-bar strip, a title taking clicks let macOS zoom the window). Renaming — ⋯ › Rename…, or a
    /// new list — swaps in an outlined field: Return or clicking away saves, Esc restores the old name.
    @ViewBuilder private var titleField: some View {
        if editingTitle && !isRolledUp {
            TextField("", text: $titleText)
                .textFieldStyle(.plain)
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.title)
                .focused($titleFocused)
                .overlay(alignment: .leading) {
                    if titleText.isEmpty { titleLabel.allowsHitTesting(false) }
                }
                .background(   // drawn outside the field, so its text stays where the label's was
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.45))
                        .strokeBorder(theme.accent.opacity(0.7))
                        .padding(.horizontal, -5)
                        .padding(.vertical, -2)
                )
                .onSubmit { titleFocused = false }
                .onExitCommand {
                    titleText = note.title
                    titleFocused = false
                }
                .onAppear { titleFocused = true }
        } else {
            titleLabel.allowsHitTesting(false)
        }
    }

    private var titleLabel: some View {
        Text(titleText.isEmpty ? "Untitled List" : titleText)
            .font(.headline.weight(.semibold))
            .foregroundStyle(titleText.isEmpty ? theme.secondary : theme.title)
            .lineLimit(1)
            .padding(.leading, 2)   // where the field draws its text, so starting a rename doesn't shift it
    }

    /// The rolled-up bar's count of tasks still to do.
    @ViewBuilder private var remainingCount: some View {
        let remaining = controller.tasks.filter { !$0.isDone }.count
        if remaining > 0 {
            Text("\(remaining)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.accent.opacity(0.18)))
                .allowsHitTesting(false)
        }
    }

    /// Commit the title, normalising the field to the trimmed value so a whitespace-only entry
    /// becomes empty and the "Untitled List" placeholder reappears.
    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != titleText { titleText = trimmed }
        controller.commitTitle(trimmed)
    }

    // MARK: - Controls

    /// Just the everyday ones in the row — the rest are under ⋯ — so they're easy to hit and the title keeps
    /// most of the row.
    private var controls: some View {
        HStack(spacing: 6) {
            if !isRolledUp { optionsButton }
            collapseButton
            floatButton
            closeButton
        }
        .confirmationDialog(
            "Delete \(controller.completedCount) completed task\(controller.completedCount == 1 ? "" : "s")? "
                + "This can't be undone.",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { controller.clearCompleted() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var optionsButton: some View {
        iconButton(systemName: "ellipsis", isActive: showOptions, help: "List options") {
            showOptions.toggle()
        }
        .popover(isPresented: $showOptions, arrowEdge: .bottom) { optionsPopover }
    }

    private var collapseButton: some View {
        iconButton(systemName: isRolledUp ? "chevron.down" : "chevron.up", isActive: false,
                   help: isRolledUp ? "Expand" : "Roll up") {
            controller.toggleCollapsed()
        }
    }

    private var floatButton: some View {
        let isFloating = note.floatOnTop
        return iconButton(
            systemName: isFloating ? "pin.fill" : "pin",
            isActive: isFloating,
            help: isFloating ? "Unpin from top" : "Keep on top"
        ) {
            controller.toggleFloatOnTop()
        }
    }

    private var closeButton: some View {
        Button {
            controller.requestClose()
        } label: {
            Hoverable { hovering in
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.red : theme.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Close list")
    }

    private func iconButton(
        systemName: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Hoverable { hovering in
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? theme.title : isActive ? theme.accent : theme.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Options popover

extension NoteHeaderView {
    /// Everything that isn't an everyday control: colour, material, the completed-task display options, and
    /// the note-level actions. `note` is `private(set)`, so each `Toggle` writes through the controller's
    /// toggle method (the binding's incoming value is ignored — the method flips + persists).
    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            popoverAction("Rename…", systemImage: "pencil") { controller.requestRename() }
            Divider()
            colorSwatches
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Glass", isOn: Binding(
                    get: { note.material == .glass },
                    set: { _ in controller.toggleMaterial() }
                ))
                Toggle("Hide completed", isOn: Binding(
                    get: { note.hideCompleted },
                    set: { _ in controller.toggleHideCompleted() }
                ))
                Toggle("Move completed to bottom", isOn: Binding(
                    get: { note.moveCompletedToBottom },
                    set: { _ in controller.toggleMoveCompletedToBottom() }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(theme.accent)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                popoverAction("New List", systemImage: "plus") { controller.requestNewNote() }
                // A "tidy up" wand rather than a trash can — this clears finished items, it isn't a delete.
                let done = controller.completedCount
                popoverAction(done > 0 ? "Clean Up \(done) Completed…" : "Clean Up Completed…",
                              systemImage: "wand.and.sparkles") { showClearConfirm = true }
                    .disabled(done == 0)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 240)
    }

    private var colorSwatches: some View {
        HStack(spacing: 8) {
            ForEach(NoteColor.allCases) { swatch in
                Button {
                    controller.setColor(swatch)
                } label: {
                    Circle()
                        .fill(swatch.fill)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(
                                swatch == note.color ? swatch.accent : Color.black.opacity(0.12),
                                lineWidth: swatch == note.color ? 2.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.displayName)
            }
        }
    }

    /// A menu-like row in the popover; it closes the popover, then acts.
    private func popoverAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            showOptions = false
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A header control's label, told whether the pointer is on it: its ink eases from the dim secondary to
/// the title's (× goes red).
private struct Hoverable<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { inside in withAnimation(.easeInOut(duration: 0.1)) { hovering = inside } }
    }
}
