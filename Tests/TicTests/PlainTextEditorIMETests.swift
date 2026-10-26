import AppKit
import Testing
@testable import Tic

/// Return during IME composition (e.g. Pinyin) belongs to the input method — it commits the raw
/// letters — so it must not also fire the editor's commit/submit (GitHub #11).
@MainActor
@Suite("PlainTextEditor IME")
struct PlainTextEditorIMETests {
    private func returnKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
    }

    private func makeEditor() -> (EditorTextView, () -> Int) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let editor = EditorTextView()
        _ = editor.layoutManager
        editor.isEditable = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        var submits = 0
        editor.onSubmit = { submits += 1 }
        return (editor, { submits })
    }

    @Test("Return submits when nothing is being composed")
    func returnSubmits() {
        let (editor, submits) = makeEditor()
        editor.keyDown(with: returnKey())
        #expect(submits() == 1)
    }

    @Test("Return mid-composition is left to the input method")
    func returnDuringCompositionDoesNotSubmit() {
        let (editor, submits) = makeEditor()
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: returnKey())
        #expect(submits() == 0)
    }
}
