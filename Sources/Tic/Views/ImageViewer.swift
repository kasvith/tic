import AppKit
import SwiftUI

/// The image window: a task's image, large and quick to open (double-click it in the note). Dressed like
/// the note it came from — its paper or glass background, a note-style header with the task as the title,
/// and keycap hints. Pinch, ⌘-scroll or ⌘+ / ⌘− zoom (⌘0 fits), scrolling pans; **Open in Preview** hands
/// it to Preview for anything more. Shows the image as currently cropped, following crop changes live,
/// and closes itself if the image goes away. Hosted in the one reusable `ImageWindow`.
struct ImageViewer: View {
    let controller: NoteController
    let taskId: UUID
    let onClose: () -> Void

    /// The stored image at full resolution, uncropped. Until it's decoded the note's thumbnail stands in,
    /// so the window shows the picture the moment it opens.
    @State private var fullImage: CGImage?
    @State private var cache = CroppedImageCache()
    @State private var hoverClose = false

    private var note: Note { controller.note }
    private var crop: CGRect? { controller.imageCrops[taskId] }

    private var theme: NoteTheme {
        NoteTheme(color: note.color, surface: note.material == .glass ? .glass : .solid)
    }

    private var title: String {
        let text = controller.tasks.first(where: { $0.id == taskId })?.text ?? ""
        return text.split(separator: "\n").first.map(String.init) ?? "Image"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let source = fullImage ?? controller.thumbnails[taskId], let crop,
                   let shown = cache.image(source, crop: crop) {
                    ZoomableImage(image: shown)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding([.horizontal, .bottom], 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoteBackground(color: note.color, material: note.material))
        .ignoresSafeArea()
        .task { fullImage = await controller.fullImage(taskId: taskId) }
        .onChange(of: crop == nil) { _, removed in
            if removed { onClose() }
        }
    }

    /// Dressed like a note's header: its controls, the title, and the accent rule — and it's the drag handle.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { openInPreview() } label: {
                    Label("Open in Preview", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Preview")

                Spacer(minLength: 0)

                ShortcutHint(glyphs: "⌘+ ⌘−", label: "zoom", theme: theme)
                ShortcutHint(glyphs: "⌘0", label: "fit", theme: theme)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hoverClose ? Color.red : theme.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverClose = $0 }
                .help("Close (Esc)")
            }
            .frame(height: 22)

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.title)
                .lineLimit(1)
                .allowsHitTesting(false)   // let the drag handle behind it take the click

            Rectangle()
                .fill(theme.accent.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(WindowMoveArea())
    }

    private func openInPreview() {
        Task {
            guard let url = await controller.previewFile(taskId: taskId) else { return }
            let workspace = NSWorkspace.shared
            if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                _ = try? await workspace.open([url], withApplicationAt: preview, configuration: .init())
            } else {
                workspace.open(url)
            }
        }
    }
}

/// The image window, styled like a note panel: a hidden, transparent title bar over full-size content
/// (rounded corners, shadow, edge resizing), no traffic lights, dragged by its header. Esc or ⌘W closes it
/// — the app's menu has no Close item for ⌘W to reach.
final class ImageWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear   // let the note background (incl. glass) show through
        hasShadow = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 240)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        center()
        setFrameAutosaveName("TicImageWindow")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if event.keyCode == 53 || (flags == .command && event.charactersIgnoringModifiers == "w") {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Zoom (AppKit)

/// The image in a magnifying scroll view — SwiftUI has no pinch-to-zoom scroll view on macOS 14.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.show(image)
    }
}

/// Fits the image to the view to start — and keeps it fitted while the window resizes — until you zoom:
/// pinch, ⌘-scroll, or ⌘+ / ⌘− (⌘0 fits again). Scrolling pans. The image is laid out at one point per
/// pixel and `magnification` does all the scaling.
final class ZoomScrollView: NSScrollView {
    static let zoomStep: CGFloat = 1.25

    private let imageView = NSImageView()
    private var shownImage: CGImage?
    /// True until the user zooms; while true, resizing re-fits the image.
    private var fitsWindow = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 16
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `image` fitted to the view (a no-op when it's already the one shown).
    func show(_ image: CGImage) {
        guard image !== shownImage else { return }
        shownImage = image
        let size = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        zoomToFit()
    }

    /// Fits the whole image in view, never enlarging it past one point per pixel.
    func zoomToFit() {
        fitsWindow = true
        let image = imageView.frame.size, visible = contentSize
        guard image.width > 0, image.height > 0, visible.width > 0, visible.height > 0 else { return }
        magnification = min(visible.width / image.width, visible.height / image.height, 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitsWindow { zoomToFit() }
    }

    override func magnify(with event: NSEvent) {
        fitsWindow = false
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let perTick: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        let factor = min(max(1 + event.scrollingDeltaY * perTick, 0.5), 2)
        zoom(by: factor, around: imageView.convert(event.locationInWindow, from: nil))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom(by: Self.zoomStep)
        case "-": zoom(by: 1 / Self.zoomStep)
        case "0": zoomToFit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Zooms by `factor`, keeping `point` (image coordinates; default: the middle of the view) in place.
    private func zoom(by factor: CGFloat, around point: NSPoint? = nil) {
        fitsWindow = false
        let visible = documentVisibleRect
        setMagnification(magnification * factor, centeredAt: point ?? NSPoint(x: visible.midX, y: visible.midY))
    }
}

/// Keeps a document smaller than the view centred, instead of pinned to the bottom-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width - rect.width) / 2 }
        if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height - rect.height) / 2 }
        return rect
    }
}
