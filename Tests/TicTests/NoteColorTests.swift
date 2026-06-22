import SwiftUI
import Testing
@testable import Tic

@Suite("NoteColor")
struct NoteColorTests {
    @Test("provides the six themes")
    func cases() {
        #expect(NoteColor.allCases.count == 6)
    }

    @Test("solid surface resolves distinct, tuned inks per role")
    func solidRoles() {
        let color = NoteColor.yellow
        #expect(color.color(.title, on: .solid) != color.color(.secondary, on: .solid))
        #expect(color.color(.task, on: .solid) != color.color(.completed, on: .solid))
    }

    @Test("glass surface falls back to adaptive system colors")
    func glassRoles() {
        let color = NoteColor.blue
        #expect(color.color(.title, on: .glass) == .primary)
        #expect(color.color(.task, on: .glass) == .primary)
        #expect(color.color(.secondary, on: .glass) == .secondary)
    }
}
