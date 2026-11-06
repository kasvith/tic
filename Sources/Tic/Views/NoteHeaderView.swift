import AppKit
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
    /// The title is being renamed (owned by `NoteView`, which holds back outside title changes meanwhile).
    @Binding var isRenaming: Bool

    @State private var showOptions = false
    @State private var showClearConfirm = false
    /// Bumped to flash the sync mark (a cycle touched this list, or Sync Now was pressed).
    @State private var syncPulse = 0
    @State private var showsSyncMark = false
    /// Nil outside the app (tests, previews), where notes never show sync.
    @Environment(FolderSync.self) private var sync: FolderSync?
    @Environment(\.openSettings) private var openSettings

    private var note: Note { controller.note }

    /// This list syncs (sync is on in Settings and for this list).
    private var listSyncs: Bool { note.isSynced && sync?.isEnabled == true }
    /// Why this list can't sync right now, if it can't.
    private var syncTrouble: String? { listSyncs ? sync?.problem : nil }

    /// Controls stay up while the options popover is open: it's a separate window, so the pointer leaves
    /// the note to reach it.
    private var showsControls: Bool { isRevealed || showOptions || showClearConfirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                titleField
                syncMark
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
        .task(id: controller.renameRequest) {   // also runs on appear, for a list that opens renaming
            if controller.renameRequest > 0, !isRolledUp { isRenaming = true }
        }
        .onChange(of: sync?.activity[note.id]) { _, _ in if listSyncs { syncPulse += 1 } }
        .task(id: syncPulse) {   // the mark shows while a sync touches the list, then fades
            guard syncPulse > 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsSyncMark = true }
            try? await Task.sleep(for: .seconds(1.6))
            while sync?.isSyncing == true, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.4)) { showsSyncMark = false } }
        }
    }

    /// Hidden at rest. It appears while a sync sends or brings this list's changes, then fades; it stays,
    /// in orange, only while sync can't reach its folder.
    @ViewBuilder private var syncMark: some View {
        let trouble = syncTrouble
        if listSyncs, trouble != nil || showsSyncMark {
            Image(systemName: trouble == nil
                  ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(trouble == nil ? theme.secondary : Color.orange)
                .help(trouble ?? "Syncing with your other Macs")
                .transition(.opacity)
        }
    }

    /// Plain text that's part of the drag handle (a press drags, a double-click rolls up — in the window's
    /// hidden title-bar strip, a title taking clicks let macOS zoom the window). Renaming — ⋯ › Rename…, or a
    /// new list — swaps in an outlined `TitleField`: Return or clicking away saves, Esc restores the old name.
    @ViewBuilder private var titleField: some View {
        if isRenaming && !isRolledUp {
            TitleField(
                text: $titleText,
                font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold),
                color: NSColor(theme.title),
                onEnd: { saved in
                    if !saved { titleText = note.title }
                    commitTitle()
                    isRenaming = false
                }
            )
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
                if let sync {
                    Toggle("Sync", isOn: Binding(
                        get: { note.isSynced && sync.isEnabled },
                        set: { _ in controller.toggleSynced() }
                    ))
                    .disabled(!sync.isEnabled)
                    .help("Keep this list the same on your other Macs")
                    if !sync.isEnabled {
                        Button("Turn on sync in Settings › Sync first.") {
                            showOptions = false
                            UserDefaults.standard.set(SettingsTab.sync.rawValue, forKey: SettingsTab.storageKey)
                            NSApp.activate()
                            openSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(theme.accent)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if listSyncs {
                    popoverAction("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        syncPulse += 1
                        sync?.syncNow()
                    }
                }
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

/// The title's rename field: an AppKit text field, not a SwiftUI `TextField` focused through `@FocusState`,
/// whose focus set from a view update behaves differently across macOS versions. This one makes itself first
/// responder once it's in the window, and ends — once — on Return or clicking away (`saved`) or Esc (not).
private struct TitleField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
    let onEnd: (_ saved: Bool) -> Void

    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.textColor = color
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Deferred: taking first responder mid-update would end editing inside a view update.
            Task { @MainActor [weak self] in self?.window?.makeFirstResponder(self) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        private var ended = false

        init(_ parent: TitleField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): end(saved: true)
            case #selector(NSResponder.cancelOperation(_:)): end(saved: false)
            default: return false
            }
            return true
        }

        func controlTextDidEndEditing(_ note: Notification) { end(saved: true) }   // clicked away

        private func end(saved: Bool) {
            guard !ended else { return }
            ended = true
            parent.onEnd(saved)
        }
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
