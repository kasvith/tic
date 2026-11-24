import Foundation

/// A list's icon, as `note.icon` stores it: an emoji ("🛒"), drawn in colour, or one of a fixed set of SF Symbols
/// ("symbol:cart"), drawn in the list's ink. Pure, so the parsing rules are unit-tested.
enum NoteIcon: Equatable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)

    static let symbolPrefix = "symbol:"

    /// The emoji the picker opens on; the first six are the common picks.
    static let pickerEmoji = [
        "🛒", "📚", "💡", "💼", "🏠", "✈️", "✅", "🎯", "📌", "🗓️", "💪", "🏃",
        "🎵", "🎮", "🍳", "🧹", "💰", "🎁", "❤️", "⭐", "🌱", "🐶", "🎓", "☕",
    ]

    /// Symbols every supported macOS (14+) has, so any Mac can draw what another one picked.
    static let symbols = [
        "cart", "book", "lightbulb", "briefcase", "house", "airplane",
        "star", "heart", "flag", "bell", "calendar", "gift",
    ]

    /// The icon `stored` names, or nil for none and for anything this Mac can't draw (an unknown symbol, text).
    init?(stored: String?) {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix(Self.symbolPrefix) {
            let name = String(stored.dropFirst(Self.symbolPrefix.count))
            guard Self.symbols.contains(name) else { return nil }
            self = .symbol(name)
        } else {
            guard let emoji = Self.emoji(in: stored), emoji == stored else { return nil }
            self = .emoji(emoji)
        }
    }

    var stored: String {
        switch self {
        case .emoji(let emoji): emoji
        case .symbol(let name): Self.symbolPrefix + name
        }
    }

    /// The first character of `text` when it's an emoji (what the Character Viewer types), else nil. A plain
    /// digit or "#" is an emoji scalar too, so a lone scalar counts only with emoji presentation; keycaps,
    /// flags, skin tones and ZWJ sequences carry more than one scalar.
    static func emoji(in text: String) -> String? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
              let scalar = first.unicodeScalars.first else { return nil }
        let isEmoji = scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && first.unicodeScalars.count > 1)
        return isEmoji ? String(first) : nil
    }
}
