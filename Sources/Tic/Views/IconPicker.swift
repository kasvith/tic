import AppKit
import SwiftUI

/// A list's icon: an emoji in its own colours, a symbol in `ink` (the note's title ink on the note).
struct NoteIconView: View {
    let icon: NoteIcon
    let ink: Color

    var body: some View {
        switch icon {
        case .emoji(let emoji): Text(emoji)
        case .symbol(let name): Image(systemName: name).foregroundStyle(ink)
        }
    }
}

/// What ⋯ › Icon opens: Emoji / Symbols tabs over a grid of picks (emoji you've picked lately first), then
/// **All emoji…** (the macOS Character Viewer, typed into the note's `EmojiCatcher`) and, while the list has an
/// icon, **Remove**.
struct IconPicker: View {
    let current: NoteIcon?
    /// Emoji picked lately, in any list (`NoteIcon.recentEmoji`).
    let recent: String
    let onPick: (NoteIcon?) -> Void
    let onAllEmoji: () -> Void

    private enum Tab { case emoji, symbols }
    @State private var tab: Tab

    init(current: NoteIcon?, recent: String, onPick: @escaping (NoteIcon?) -> Void,
         onAllEmoji: @escaping () -> Void) {
        self.current = current
        self.recent = recent
        self.onPick = onPick
        self.onAllEmoji = onAllEmoji
        if case .symbol = current { _tab = State(initialValue: .symbols) } else { _tab = State(initialValue: .emoji) }
    }

    private var items: [NoteIcon] {
        tab == .emoji ? NoteIcon.emojiGrid(recent: recent).map(NoteIcon.emoji) : NoteIcon.symbols.map(NoteIcon.symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: $tab) {
                Text("Emoji").tag(Tab.emoji)
                Text("Symbols").tag(Tab.symbols)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 6), spacing: 4) {
                ForEach(items, id: \.self) { icon in
                    Button { onPick(icon) } label: {
                        // The popover follows the system appearance, so symbols preview in .primary here.
                        NoteIconView(icon: icon, ink: .primary)
                            .font(.system(size: 17))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(icon == current ? Color.primary.opacity(0.12) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 12) {
                if tab == .emoji {
                    Button(action: onAllEmoji) { Label("All emoji…", systemImage: "ellipsis") }
                        .help("Opens the macOS Character Viewer")
                }
                Spacer(minLength: 0)
                // An eraser, not a trash can: this clears the icon, the list stays.
                if current != nil {
                    Button { onPick(nil) } label: { Label("Remove", systemImage: "eraser") }
                        .help("Remove this list's icon")
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 212)
    }
}

/// An invisible one-character field in the note that takes what the Character Viewer types: All emoji… makes
/// it first responder, and the first emoji typed into it becomes the icon. It's in the note, not the ⋯ menu,
/// because the viewer types into the window that has the keyboard, and that has to be the note, so the menu
/// steps aside while the viewer is up and comes back once an emoji arrives (`NoteHeaderView`).
struct EmojiCatcher: NSViewRepresentable {
    @Binding var isActive: Bool
    let onEmoji: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alphaValue = 0
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard isActive, field.currentEditor() == nil else { return }
        Task { @MainActor in   // not from inside a view update
            NSApp.activate()   // the viewer types into the active app's key window
            field.window?.makeKeyAndOrderFront(nil)
            field.window?.makeFirstResponder(field)
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EmojiCatcher

        init(_ parent: EmojiCatcher) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if let emoji = NoteIcon.emoji(in: field.stringValue) { parent.onEmoji(emoji) }
            field.stringValue = ""
            parent.isActive = false
            field.window?.makeFirstResponder(nil)
        }

        func controlTextDidEndEditing(_ note: Notification) { parent.isActive = false }
    }
}
