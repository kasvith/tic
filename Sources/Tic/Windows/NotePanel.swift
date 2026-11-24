import AppKit
import SwiftUI

/// A single sticky note window. A titled panel with a hidden, transparent title bar gives us
/// rounded corners, a system shadow, and edge resizing for free, while `fullSizeContentView`
/// lets the SwiftUI content cover the whole surface. `nonactivatingPanel` keeps clicking a note
/// from yanking the whole app forward — it behaves like a desktop sticky.
final class NotePanel: NSPanel {
    let noteID: UUID

    private static let noteStyle: NSWindow.StyleMask = [
        .titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel,
    ]

    init(note: Note, content: AnyView) {
        self.noteID = note.id

        let width = max(note.frameW, NoteLayout.minWidth)
        let rect = NSRect(x: note.frameX, y: note.frameY, width: width, height: note.frameH)
        super.init(
            contentRect: rect,
            styleMask: Self.noteStyle,
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The window is dragged only by its header (a WindowMoveArea), NOT the whole body —
        // otherwise starting a task-row drag would move the window instead of reordering.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false            // stay visible when another app is focused
        isOpaque = false
        backgroundColor = .clear             // let the SwiftUI background (incl. glass) show through
        hasShadow = true
        isReleasedWhenClosed = false         // the window manager owns the lifetime
        animationBehavior = .utilityWindow

        hideWindowButtons()

        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        // `NoteWindowManager` alone sizes the panel. Left on, the hosting view resizes the window from inside a
        // layout pass whenever the content's minimum changes (the hover controls do), and a rolled-up bar has so
        // few views that AppKit's limit on layout passes (one per view) aborts the app (issue 22).
        hosting.sizingOptions = []
        contentView = hosting

        apply(floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Rolled up or docked as a tab, the note drops the system frame and draws its own shape (a capsule, a
    /// tab): macOS rounds a titled window's corners at a fixed 16pt, too round for a thin bar — the system
    /// outline and corner mask split away from the note's fill at both ends. It drops the system shadow too:
    /// a frameless window's shadow traces the shape with a dark rim, which reads as a border on a light desktop.
    func setFrameless(_ frameless: Bool) {
        guard styleMask.contains(.titled) == frameless else { return }
        styleMask = frameless ? [.borderless, .resizable, .nonactivatingPanel] : Self.noteStyle
        hasShadow = !frameless
        hideWindowButtons()   // a titled frame comes back with fresh traffic lights
    }

    /// Hides the traffic-light buttons; notes get their own controls in the header.
    private func hideWindowButtons() {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    /// Applies the float-on-top and show-on-all-Spaces behaviours to the live window. All Spaces only counts
    /// while pinned (⋯ › Over full-screen apps shows only then), or for a docked tab when Settings says tabs
    /// show over full-screen apps: joining every Space, full-screen apps' included, with `.fullScreenAuxiliary`
    /// is what keeps a note above an app in full screen. A Dock-icon app can do this because the panel is
    /// non-activating (checked on macOS 26, Nov 2026).
    func apply(floatOnTop: Bool, showOnAllSpaces: Bool, tabOnAllSpaces: Bool = false) {
        level = floatOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if (floatOnTop && showOnAllSpaces) || tabOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        collectionBehavior = behavior
    }

    /// Borderless/utility panels don't become key by default; we need it for text editing.
    override var canBecomeKey: Bool { true }

    /// Called when a drag by the note's header has been let go. Set by `NoteWindowManager`.
    var onDragEnded: (() -> Void)?

    /// Picks the frame for each step of a drag, given the pointer and the frame a plain move would give (the
    /// size at the drag's start): the manager folds a note into a tab at a display edge, and back. Set by
    /// `NoteWindowManager`; without it the note just moves.
    var onDragMove: ((_ pointer: NSPoint, _ proposed: NSRect) -> NSRect)?

    /// Moves the note with the pointer from `press` (the header's mouse-down, `WindowMoveArea`) until mouse-up.
    /// Not the system's window drag: that returns at once, macOS settles or tiles a window let go at a screen
    /// edge (fighting the bottom snap, issue 18), and its session swallowed a double-click's second click.
    /// The top edge stays below the menu bar, as the system drag kept it.
    override func performDrag(with press: NSEvent) {
        let start = convertPoint(toScreen: press.locationInWindow)
        // A frame animation still running (a tab sliding out) keeps setting the frame and would fight the drag;
        // a plain `setFrame` doesn't stop one (probed), replacing it with a zero-length one does.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().setFrame(frame, display: false)
        }
        let startFrame = frame
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            let pointer = NSEvent.mouseLocation
            var next = NSPoint(x: startFrame.minX + pointer.x - start.x, y: startFrame.minY + pointer.y - start.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
                next.y = min(next.y, screen.visibleFrame.maxY - startFrame.height)
            }
            let proposed = NSRect(origin: next, size: startFrame.size)
            let target = onDragMove?(pointer, proposed) ?? proposed
            // Only a fold into a tab (or back) resizes; a plain drag just moves, without redrawing the note.
            if target.size == frame.size { setFrameOrigin(target.origin) } else { setFrame(target, display: true) }
        }
        onDragEnded?()
    }

    // MARK: - Paste

    /// Hands over a pasted image, which waits in the note's quick-add. Reached when nothing in the note
    /// is being edited — a focused editor handles ⌘V itself, earlier in the responder chain. Set by
    /// `NoteWindowManager`.
    var onPasteImage: ((Data) -> Void)?

    @objc func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.pastableImageData() { onPasteImage?(data) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.hasPastableImage }
        return super.validateUserInterfaceItem(item)
    }
}
