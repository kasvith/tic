import SwiftUI
import AppKit

/// A note's background. `.solid` paints the paper fill; `.glass` shows the desktop through a
/// frosted, appearance-adaptive material (the "widget"/Stickies glass look), faintly tinted with
/// the theme colour. The material is `behindWindow`-blended so it samples whatever sits behind
/// the note's window, and it adopts the Liquid Glass appearance automatically on macOS 26.
struct NoteBackground: View {
    let color: NoteColor
    let material: NoteMaterial
    /// The note's own corner rounding — only for a rolled-up bar, which has no system window frame to round it.
    var cornerRadius: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch material {
        case .solid:
            shape.fill(color.fill)
        case .glass:
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow, cornerRadius: cornerRadius)
                shape.fill(color.fill.opacity(0.18))   // a hint of the theme over the glass
            }
        }
    }
}

/// Bridges `NSVisualEffectView` so a note window can show frosted, desktop-sampling translucency.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active   // keep the effect visible even when the window isn't key
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
        nsView.maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
    }

    /// A stretchable rounded-rect mask: the way to round a behind-window effect view (layer masks don't apply).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
