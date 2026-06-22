import SwiftUI

/// A tiny, unobtrusive shortcut label — a soft keycap chip for the chord (e.g. "⇧⏎") plus a
/// one-word action, in the note's muted ink. Used inline next to the field it applies to (the
/// quick-add, or a task being edited) so the handful of useful chords are visible without a heavy
/// keycap rail. Theme-aware so it reads on every paper colour and on glass.
struct ShortcutHint: View {
    let glyphs: String
    let label: String
    let theme: NoteTheme

    var body: some View {
        HStack(spacing: 5) {
            Text(glyphs)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.accent.opacity(theme.isGlass ? 0.12 : 0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.22), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondary.opacity(0.9))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("\(label) shortcut")
    }
}
