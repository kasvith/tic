import CoreGraphics
import Testing
@testable import Tic

@Suite("Edge dock geometry")
struct DockLayoutTests {
    // A laptop at the origin and a monitor to its right; menu bar 24pt, Dock 70pt at the bottom of the laptop.
    private let laptop = DockLayout.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                            visible: CGRect(x: 0, y: 70, width: 1440, height: 806))
    private let monitor = DockLayout.Display(frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                                             visible: CGRect(x: 1440, y: 0, width: 2560, height: 1415))
    private var both: [DockLayout.Display] { [laptop, monitor] }

    @Test("only outer edges dock: the seam between two displays doesn't")
    func outerEdgesOnly() {
        #expect(DockLayout.edge(at: CGPoint(x: 3, y: 400), in: both)?.edge == .left)
        #expect(DockLayout.edge(at: CGPoint(x: 3999, y: 400), in: both)?.edge == .right)
        #expect(DockLayout.edge(at: CGPoint(x: 1439, y: 400), in: both) == nil)   // laptop's right edge: seam
        #expect(DockLayout.edge(at: CGPoint(x: 1441, y: 400), in: both) == nil)   // monitor's left edge: seam
        // Above the laptop's top, the monitor's left edge has nothing beside it: an outer edge there.
        #expect(DockLayout.edge(at: CGPoint(x: 1441, y: 1200), in: both)?.edge == .left)
        #expect(DockLayout.edge(at: CGPoint(x: 700, y: 400), in: both) == nil)
        // Alone, the laptop's right edge docks.
        #expect(DockLayout.edge(at: CGPoint(x: 1439, y: 400), in: [laptop])?.edge == .right)
    }

    @Test("a tab sits flush with its edge and inside the visible frame")
    func tabFrame() {
        let size = CGSize(width: 26, height: 120)
        let right = DockLayout.tabFrame(.right, top: 600, size: size, in: laptop.visible)
        #expect(right == CGRect(x: 1414, y: 480, width: 26, height: 120))
        let high = DockLayout.tabFrame(.left, top: 5000, size: size, in: laptop.visible)
        #expect(high.minX == 0 && high.maxY == laptop.visible.maxY - DockLayout.margin)
        let low = DockLayout.tabFrame(.left, top: 0, size: size, in: laptop.visible)
        #expect(low.minY == laptop.visible.minY + DockLayout.margin)
    }

    @Test("overlapping tabs move apart, top first; a stack off the bottom is pushed back up")
    func stacking() {
        let a = CGRect(x: 1414, y: 500, width: 26, height: 100)   // 500–600
        let b = CGRect(x: 1414, y: 520, width: 26, height: 100)   // 520–620: overlaps a, and is higher
        let out = DockLayout.stacked([a, b], in: laptop.visible)
        #expect(out[1].maxY == 620)                                  // the higher one keeps its place
        #expect(out[0].maxY == 620 - 100 - DockLayout.gap)           // the other goes below it
        let bottom = DockLayout.stacked([CGRect(x: 0, y: 80, width: 26, height: 100), CGRect(x: 0, y: 70, width: 26, height: 100)],
                                        in: laptop.visible)
        #expect(bottom.allSatisfy { $0.minY >= laptop.visible.minY + DockLayout.margin })
        #expect(bottom[0].minY >= bottom[1].maxY + DockLayout.gap || bottom[1].minY >= bottom[0].maxY + DockLayout.gap)
    }

    @Test("a peek is full size, flush with the edge, level with the tab, and stays on screen")
    func peek() {
        let tab = CGRect(x: 1414, y: 480, width: 26, height: 120)
        let peek = DockLayout.peekFrame(.right, tab: tab, size: CGSize(width: 280, height: 360), in: laptop.visible)
        #expect(peek == CGRect(x: 1160, y: 240, width: 280, height: 360))
        let lowTab = CGRect(x: 0, y: 78, width: 26, height: 64)
        let low = DockLayout.peekFrame(.left, tab: lowTab, size: CGSize(width: 280, height: 360), in: laptop.visible)
        #expect(low.minX == 0 && low.minY == laptop.visible.minY)
    }

    @Test("a frame on a vanished display falls back to the main one; the nearer edge is picked")
    func displaysAndEdges() {
        let offScreen = CGRect(x: 5000, y: 300, width: 280, height: 360)
        #expect(DockLayout.display(for: offScreen, in: both) == laptop)
        #expect(DockLayout.display(for: CGRect(x: 2000, y: 300, width: 280, height: 360), in: both) == monitor)
        #expect(DockLayout.nearestEdge(of: CGRect(x: 100, y: 300, width: 280, height: 360), on: laptop) == .left)
        #expect(DockLayout.nearestEdge(of: CGRect(x: 1100, y: 300, width: 280, height: 360), on: laptop) == .right)
    }
}
