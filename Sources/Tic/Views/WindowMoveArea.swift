import SwiftUI
import AppKit

/// A transparent layer that lets the user drag the window by this region (the note's title-bar
/// handle) and reports double-clicks (for roll-up). Used because whole-window background dragging
/// is disabled on the panel — so dragging a task row reorders it instead of moving the window.
struct WindowMoveArea: NSViewRepresentable {
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        MoveView(onClick: onClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MoveView)?.onClick = onClick
        (nsView as? MoveView)?.onDoubleClick = onDoubleClick
    }

    final class MoveView: NSView {
        var onClick: () -> Void
        var onDoubleClick: () -> Void

        init(onClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// A press that hasn't moved yet. The window drag starts only once it does, so a click or a
        /// double-click (roll-up) never counts as a drag — a note snaps when one is let go.
        private var pendingPress: NSEvent?

        override func mouseDown(with event: NSEvent) {
            pendingPress = nil
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            pendingPress = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press = pendingPress else { return }
            pendingPress = nil
            window?.performDrag(with: press)   // a note's own drag (`NotePanel`), else the system's
        }

        /// A press let go without moving: a click (a docked tab opens on one).
        override func mouseUp(with event: NSEvent) {
            if pendingPress != nil { onClick() }
            pendingPress = nil
        }
    }
}
