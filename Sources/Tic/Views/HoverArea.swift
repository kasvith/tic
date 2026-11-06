import AppKit
import SwiftUI

/// Reports the pointer entering and leaving its frame, from an AppKit tracking area. A note's hover reveal
/// uses this, not SwiftUI's `.onHover`, which often didn't fire until the note had been clicked into (most of
/// the header row it reveals is the AppKit drag handle). A tracking area goes by geometry alone — whatever
/// view is under the pointer, key window or not, Tic active or not. It never takes a click.
struct HoverArea: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView(onChange: onChange) }

    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
            ))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
