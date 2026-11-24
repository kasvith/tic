import Foundation
import Testing
@testable import Tic

@Suite("List icons")
struct NoteIconTests {
    @Test("stored icons round-trip; unknown symbols, text and empty values are no icon")
    func storedRoundTrip() {
        for icon in [NoteIcon.emoji("🛒"), .emoji("✈️"), .symbol("cart"), .symbol("gift")] {
            #expect(NoteIcon(stored: icon.stored) == icon)
        }
        #expect(NoteIcon(stored: "symbol:cart")?.stored == "symbol:cart")
        #expect(NoteIcon(stored: "symbol:not.a.symbol") == nil)
        #expect(NoteIcon(stored: "Groceries") == nil)
        #expect(NoteIcon(stored: "🛒 Groceries") == nil)   // an icon is one emoji, nothing else
        #expect(NoteIcon(stored: "") == nil)
        #expect(NoteIcon(stored: nil) == nil)
    }

    @Test("emoji(in:) takes a leading emoji, including flags, skin tones, ZWJ and keycaps, but not digits or #")
    func emojiDetection() {
        #expect(NoteIcon.emoji(in: "🛒") == "🛒")
        #expect(NoteIcon.emoji(in: "  ☕ coffee") == "☕")
        #expect(NoteIcon.emoji(in: "✈️") == "✈️")
        #expect(NoteIcon.emoji(in: "🇱🇰") == "🇱🇰")
        #expect(NoteIcon.emoji(in: "👍🏽") == "👍🏽")
        #expect(NoteIcon.emoji(in: "👩‍💻") == "👩‍💻")
        #expect(NoteIcon.emoji(in: "1️⃣") == "1️⃣")
        #expect(NoteIcon.emoji(in: "1") == nil)
        #expect(NoteIcon.emoji(in: "#") == nil)
        #expect(NoteIcon.emoji(in: "a") == nil)
        #expect(NoteIcon.emoji(in: "") == nil)
    }

    @Test("every picker emoji is a valid stored icon")
    func pickerIsValid() {
        for emoji in NoteIcon.pickerEmoji { #expect(NoteIcon(stored: emoji) == .emoji(emoji)) }
    }
}
