import AppKit
import SwiftUI

/// A borderless, transparent, auto-growing multiline text editor backed by `NSTextView`.
///
/// We use AppKit here rather than SwiftUI's `TextField(axis: .vertical)` because, on macOS, that
/// control neither reliably inserts line breaks nor lets us intercept Tab (the AppKit key-view loop
/// swallows it before SwiftUI's `.onKeyPress` runs). An `NSTextView` subclass that overrides
/// `keyDown` gives deterministic control:
///   • **Return** → `onCommit` (finish)            • **Shift/Option-Return** → insert a line break
///   • **Shift-Tab** → `onIndent` (nest deeper)    • **Ctrl-Shift-Tab** → `onOutdent` (promote)
///   • **Esc** → `onCommit`
/// It grows to fit its content via `sizeThatFits` and commits on focus loss.
struct PlainTextEditor: NSViewRepresentable {
    /// Vertical inset above the first text line (matches `textContainerInset.height`); used to align
    /// an adjacent checkbox/icon to the editor's first baseline.
    static let topInset: CGFloat = 2

    @Binding var text: String
    var textColor: Color
    var font: NSFont = .preferredFont(forTextStyle: .body)
    /// Grab the keyboard as soon as the view appears (true for tap-to-edit rows, false for the
    /// always-present quick-add field, which should only focus on click).
    var autoFocus: Bool = false
    var onCommit: () -> Void = {}
    /// Fired *only* on a plain Return — not on Esc or focus loss (both of which call `onCommit`). Lets
    /// a caller distinguish "the user pressed Return to move on" from "editing ended", e.g. to open
    /// the next row in a rapid-add flow without a blur/Esc spuriously triggering it.
    var onSubmit: () -> Void = {}
    var onIndent: () -> Void = {}
    var onOutdent: () -> Void = {}
    /// Fired when the editor gains (`true`) / loses (`false`) first-responder, so the note can show
    /// its contextual shortcut hints only while a field is actually being edited.
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        // macOS 14 NSTextViews default to TextKit 2, where `layoutManager` is nil. Touching the
        // property forces TextKit 1 (a documented compatibility fallback), so `layoutManager` and
        // `usedRect` are available to measure content height — without it multiline text would be
        // clipped to a single line.
        _ = view.layoutManager
        view.delegate = context.coordinator
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        configure(view)
        view.string = text
        // Grab focus once the view is actually in a window (see `EditorTextView.viewDidMoveToWindow`).
        // The window-entry hook fires the moment the (eagerly-realised, non-lazy) row attaches to the
        // window — reliable regardless of whether the row is on screen yet. A one-shot
        // `makeFirstResponder` here would no-op for a row created off-screen.
        view.autoFocusesOnAppear = autoFocus
        return view
    }

    func updateNSView(_ view: EditorTextView, context: Context) {
        if view.string != text { view.string = text }
        configure(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width))
    }

    private func configure(_ view: EditorTextView) {
        view.onCommit = onCommit
        view.onSubmit = onSubmit
        view.onIndent = onIndent
        view.onOutdent = onOutdent
        view.onFocusChange = onFocusChange
        view.font = font
        view.textColor = NSColor(textColor)
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: Self.topInset)
        view.textContainer?.lineFragmentPadding = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// Distance from the editor's top to its first text line's baseline, for baseline alignment.
    var firstBaseline: CGFloat { Self.topInset + font.ascender }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            (notification.object as? EditorTextView)?.onCommit()
        }
    }
}

/// `NSTextView` subclass that routes the editor's key chords to closures and reports the height it
/// needs for a given width so SwiftUI can lay it out.
final class EditorTextView: NSTextView {
    var onCommit: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onIndent: () -> Void = {}
    var onOutdent: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    /// When true, the view makes itself first responder the first time it lands in a window.
    var autoFocusesOnAppear = false
    private var didAutoFocus = false

    /// Grabs first-responder a single time, once the view is in a window and not already focused.
    /// Driven by `viewDidMoveToWindow`, which fires the moment the (eagerly-realised) row attaches to
    /// the window — so it works whether or not the row is on screen yet. Bringing the row into view is
    /// left to SwiftUI's `ScrollViewReader`: an AppKit `scrollToVisible` is a no-op inside a SwiftUI
    /// `ScrollView`, which owns the clip view's content offset and reasserts it on the next layout.
    func focusIfNeeded() {
        guard autoFocusesOnAppear, !didAutoFocus, let window, window.firstResponder !== self else { return }
        didAutoFocus = true
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    private enum Key {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case Key.tab where mods.contains(.shift):
            if mods.contains(.control) { onOutdent() } else { onIndent() }
        case Key.returnKey, Key.keypadEnter:
            if mods.contains(.shift) || mods.contains(.option) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onCommit()
                onSubmit()   // Return-only; lets callers continue (e.g. open the next add row)
            }
        case Key.escape:
            onCommit()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The container doesn't track our width on its own (widthTracksTextView is off), so keep it
        // in sync with the real frame — otherwise text wraps at a stale, narrower width.
        if let container = textContainer, container.containerSize.width != newSize.width {
            container.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// Fallback height (used if SwiftUI consults intrinsic size before `sizeThatFits`).
    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : (textContainer?.containerSize.width ?? 0)
        return NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: width))
    }

    /// Height needed to lay the current text out at `width`, clamped to at least one line.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let container = textContainer else { return lineHeight }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        return ceil(max(used, lineHeight)) + textContainerInset.height * 2
    }

    private var lineHeight: CGFloat {
        guard let font else { return 16 }
        return layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
    }
}

extension View {
    /// Aligns this view's `firstTextBaseline` to a sibling `PlainTextEditor`'s first text line.
    /// The editor's `NSView` reports no text baseline, so without this an adjacent checkbox/icon in
    /// an `HStack(alignment: .firstTextBaseline)` hangs below the editor's empty box.
    @MainActor
    func editorFirstBaseline(font: NSFont = .preferredFont(forTextStyle: .body)) -> some View {
        // Resolve the baseline up front so the (`@Sendable`) alignment-guide closure captures only a
        // plain CGFloat — not the non-Sendable NSFont or the main-actor `topInset`.
        let baseline = PlainTextEditor.topInset + font.ascender
        return alignmentGuide(.firstTextBaseline) { _ in baseline }
    }
}
