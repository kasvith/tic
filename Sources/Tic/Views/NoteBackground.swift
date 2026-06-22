import SwiftUI
import AppKit

/// A note's background. `.solid` paints the paper fill; `.glass` shows the desktop through a
/// frosted, appearance-adaptive material (the "widget"/Stickies glass look), faintly tinted with
/// the theme colour. The material is `behindWindow`-blended so it samples whatever sits behind
/// the note's window, and it adopts the Liquid Glass appearance automatically on macOS 26.
struct NoteBackground: View {
    let color: NoteColor
    let material: NoteMaterial

    var body: some View {
        switch material {
        case .solid:
            color.fill
        case .glass:
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow)
                color.fill.opacity(0.18)   // a hint of the theme over the glass
            }
        }
    }
}

/// Bridges `NSVisualEffectView` so a note window can show frosted, desktop-sampling translucency.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active   // keep the effect visible even when the window isn't key
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
    }
}
