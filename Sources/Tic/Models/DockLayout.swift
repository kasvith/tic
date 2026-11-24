import CoreGraphics

/// The display edge a note is docked to (per Mac, like its frame).
enum DockEdge: String, Codable, Sendable {
    case left, right
}

/// How a docked note's tab looks (Settings › General › Docked tabs).
enum DockTabStyle: String, CaseIterable, Identifiable, Sendable {
    case sliver, title, titleCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sliver: "Sliver"
        case .title: "Title"
        case .titleCount: "Title + count"
        }
    }
}

/// The edge dock's geometry, pure like `NoteWindowManager.rolledFrame`, so every rule is unit-tested. Rects are
/// global AppKit coordinates (origin bottom-left), as the note frames are.
enum DockLayout {
    /// A display: its whole frame (to find the one the pointer is on) and its visible frame (to place tabs
    /// beside the menu bar and the Dock).
    struct Display: Equatable, Sendable {
        var frame: CGRect
        var visible: CGRect
    }

    /// How close to a display's outer edge the pointer must come for a dragged note to fold into a tab.
    static let zone: CGFloat = 24
    /// How close counts as pointing at the edge, to bring covered tabs forward.
    static let edgeHover: CGFloat = 3
    /// A tab is never wider than this (a note never narrower than `NoteLayout.minWidth`), so a window this
    /// narrow is a tab: that's how `NoteView` knows which to draw.
    static let maxTabWidth: CGFloat = 26
    static let sliverWidth: CGFloat = 10
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// The left or right edge of the display `pointer` is on, if it's within `zone` of one. Edges between two
    /// displays dock too: a note dragged across folds into a tab for a moment, and docks only if let go there.
    static func edge(at pointer: CGPoint, in displays: [Display], zone: CGFloat = zone) -> (edge: DockEdge, display: Display)? {
        guard let display = displays.first(where: { contains($0.frame, pointer) }) else { return nil }
        if pointer.x <= display.frame.minX + zone { return (.left, display) }
        if pointer.x >= display.frame.maxX - zone { return (.right, display) }
        return nil
    }

    /// A tab of `size` flush with `edge`, its top at `top`, kept inside the visible frame.
    static func tabFrame(_ edge: DockEdge, top: CGFloat, size: CGSize, in visible: CGRect) -> CGRect {
        let x = edge == .left ? visible.minX : visible.maxX - size.width
        let maxY = min(max(top, visible.minY + margin + size.height), visible.maxY - margin)
        return CGRect(x: x, y: maxY - size.height, width: size.width, height: size.height)
    }

    /// The same tabs (one edge of one display), moved apart where they'd overlap: the higher one keeps its
    /// place and the next goes below it; a stack running off the bottom is pushed back up. Same order as given.
    static func stacked(_ tabs: [CGRect], in visible: CGRect) -> [CGRect] {
        var out = tabs
        let order = tabs.indices.sorted { tabs[$0].maxY > tabs[$1].maxY }
        var ceiling = visible.maxY - margin
        for i in order {
            out[i].origin.y = min(out[i].maxY, ceiling) - out[i].height
            ceiling = out[i].minY - gap
        }
        var floor = visible.minY + margin
        for i in order.reversed() {
            out[i].origin.y = max(out[i].minY, floor)
            floor = out[i].maxY + gap
        }
        return out
    }

    /// Where a docked note shows when it peeks: full size, flush with its edge, level with its tab's top.
    static func peekFrame(_ edge: DockEdge, tab: CGRect, size: CGSize, in visible: CGRect) -> CGRect {
        let height = min(size.height, visible.height)
        let x = edge == .left ? visible.minX : visible.maxX - size.width
        let y = max(min(tab.maxY, visible.maxY) - height, visible.minY)
        return CGRect(x: x, y: y, width: size.width, height: height)
    }

    /// The display most of `frame` is on, or the first (main) one if it's on none (its display was unplugged).
    static func display(for frame: CGRect, in displays: [Display]) -> Display? {
        let area = { (d: Display) in d.frame.intersection(frame).width * d.frame.intersection(frame).height }
        return displays.filter { area($0) > 0 }.max { area($0) < area($1) } ?? displays.first
    }

    /// The nearer side edge of `display` for a note at `frame` (⋯ › Dock to Edge).
    static func nearestEdge(of frame: CGRect, on display: Display) -> DockEdge {
        frame.midX < display.visible.midX ? .left : .right
    }

    /// `CGRect.contains` leaves out the max edges; the pointer can sit on the last column of a display.
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
