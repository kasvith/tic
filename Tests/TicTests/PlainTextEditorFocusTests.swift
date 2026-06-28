import AppKit
import SwiftUI
import Testing
@testable import Tic

/// Focus mechanism of the inline editor, exercised directly (no SwiftUI list around it).
///
/// These verify the AppKit half of rapid-add: an `EditorTextView` flagged `autoFocusesOnAppear`
/// must grab the keyboard the moment it lands in a window (`viewDidMoveToWindow`), and only once.
/// They pass in isolation, which is the point — when the live app drops focus during rapid-add it's
/// the *list container* failing to realise the row (so this code never runs), not this code itself.
@MainActor
@Suite("PlainTextEditor focus")
struct PlainTextEditorFocusTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared   // ensure the shared app exists before making a window
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    private func makeEditor(autoFocus: Bool) -> EditorTextView {
        let editor = EditorTextView()
        _ = editor.layoutManager   // force TextKit 1, as production makeNSView does
        editor.isEditable = true
        editor.isSelectable = true
        editor.autoFocusesOnAppear = autoFocus
        return editor
    }

    @Test("an editor flagged autoFocusesOnAppear grabs first responder when it enters a window")
    func grabsFocusOnWindowEntry() {
        let window = makeWindow()
        let editor = makeEditor(autoFocus: true)
        window.contentView = editor   // triggers viewDidMoveToWindow → focusIfNeeded
        #expect(window.firstResponder === editor)
    }

    @Test("an editor without the flag does not grab first responder")
    func noFocusWithoutFlag() {
        let window = makeWindow()
        let editor = makeEditor(autoFocus: false)
        window.contentView = editor
        #expect(window.firstResponder !== editor)
    }

    @Test("focus is one-shot: after it resigns, re-entering a window does not re-steal focus")
    func focusIsOneShot() {
        let window = makeWindow()
        let editor = makeEditor(autoFocus: true)
        window.contentView = editor
        #expect(window.firstResponder === editor)

        // Drop focus, move the editor out of the window and back in.
        window.makeFirstResponder(nil)
        editor.removeFromSuperview()
        let host = NSView(frame: window.frame)
        window.contentView = host
        host.addSubview(editor)   // viewDidMoveToWindow fires again

        // The per-instance one-shot guard must keep it from grabbing focus a second time.
        #expect(window.firstResponder !== editor)
    }
}
