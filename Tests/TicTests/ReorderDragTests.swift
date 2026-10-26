import AppKit
import SwiftUI
import Testing
@testable import Tic

/// The reorder drag end to end: a real `NoteView` in a real `NotePanel`, driven by synthetic mouse
/// events delivered through `NSWindow.sendEvent` — the path a real click takes into SwiftUI.
///
/// These pin down the "stuck drag": swapping the dragged row's view out for the placeholder removed
/// the view holding the drag's mouse-down, so ~0.2s after pickup SwiftUI silently stopped delivering
/// the drag's events — it never ended or cancelled, so the lifted row and placeholder stayed put.
///
/// Events go straight to the window (not `NSApp.postEvent` + a hand-pumped `nextEvent` loop, which
/// left the main actor unserviced for the next test), and each mouse-down is first hit-tested onto
/// SwiftUI content: a press on a text field would start an AppKit tracking loop that never returns.
@MainActor
@Suite("Reorder drag (hosted NoteView)", .serialized)
struct ReorderDragTests {
    @MainActor struct Harness {
        let panel: NotePanel
        let controller: NoteController
        let drag: ReorderDrag
        var top: CGFloat { panel.contentView!.bounds.height }
        var order: [String] { controller.tasks.map(\.text) }
    }

    private func makeHarness(_ tasks: [(String, Int)]) async throws -> Harness {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        let controller = NoteController(note: note, database: db)
        for (text, level) in tasks { controller.addTask(text, level: level) }
        let drag = ReorderDrag()
        let panel = NotePanel(note: note, content: AnyView(NoteView(controller: controller, drag: drag)))
        panel.makeKeyAndOrderFront(nil)
        pump(0.3)
        return Harness(panel: panel, controller: controller, drag: drag)
    }

    private func makeHarness(_ texts: [String] = ["A", "B", "C", "D", "E", "F"]) async throws -> Harness {
        try await makeHarness(texts.map { ($0, 0) })
    }

    /// Lets SwiftUI process pending updates.
    private func pump(_ seconds: TimeInterval = 0.02) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func send(_ type: NSEvent.EventType, _ point: NSPoint, to h: Harness) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: h.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
        h.panel.sendEvent(event)
        pump()
    }

    /// Drags in `steps` even moves from `from` to `to`.
    private func drag(_ h: Harness, from: NSPoint, to: NSPoint, steps: Int = 10) {
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), to: h)
        }
    }

    /// Presses on the first row and nudges it so the drag starts; returns where the pointer now is.
    private func pickUpFirstRow(_ h: Harness) throws -> NSPoint {
        let start = NSPoint(x: 60, y: h.top - 80)
        let hit = try #require(h.panel.contentView?.hitTest(start))
        try #require(String(describing: type(of: hit)).contains("PlatformGroupContainer"), "not on a task row")
        send(.leftMouseDown, start, to: h)
        let nudged = NSPoint(x: start.x, y: start.y - 6)
        send(.leftMouseDragged, nudged, to: h)
        try #require(h.drag.taskID != nil, "the drag didn't start")
        return nudged
    }

    @Test("a drag drops where the placeholder is")
    func dropsAtPlaceholder() async throws {
        let h = try await makeHarness()
        let at = try pickUpFirstRow(h)
        drag(h, from: at, to: NSPoint(x: at.x, y: at.y - 46))
        send(.leftMouseUp, NSPoint(x: at.x, y: at.y - 46), to: h)
        pump(0.3)
        #expect(h.drag.taskID == nil)
        #expect(h.order == ["B", "C", "A", "D", "E", "F"])
    }

    @Test("pausing mid-drag doesn't kill the drag (the stuck-drag regression)")
    func survivesPause() async throws {
        let h = try await makeHarness()
        let at = try pickUpFirstRow(h)
        pump(0.6)   // well past the pickup animation, which used to remove the pressed view
        let before = h.drag.location
        drag(h, from: at, to: NSPoint(x: at.x, y: at.y - 46))
        #expect(h.drag.location != before, "the drag stopped receiving events")
        send(.leftMouseUp, NSPoint(x: at.x, y: at.y - 46), to: h)
        pump(0.3)
        #expect(h.drag.taskID == nil)
        #expect(h.order.firstIndex(of: "A") == 2)
    }

    @Test("leaving the note and coming back keeps tracking and still drops", arguments: ["right", "left", "below", "above"])
    func leavesAndReturns(_ side: String) async throws {
        let h = try await makeHarness()
        let at = try pickUpFirstRow(h)
        let away = switch side {
        case "right": NSPoint(x: 420, y: at.y - 30)
        case "left": NSPoint(x: -120, y: at.y - 30)
        case "below": NSPoint(x: 60, y: -120)
        default: NSPoint(x: 60, y: h.top + 120)
        }
        drag(h, from: at, to: away)
        let outside = h.drag.location
        let back = NSPoint(x: at.x, y: at.y - 46)
        drag(h, from: away, to: back)
        #expect(h.drag.location != outside, "the drag stopped receiving events outside the note")
        send(.leftMouseUp, back, to: h)
        pump(0.3)
        #expect(h.drag.taskID == nil, "the drag is stuck")
        #expect((2...3).contains(h.order.firstIndex(of: "A") ?? -1))   // 3 when coming back up from below
    }

    @Test("releasing outside the note never leaves the drag stuck")
    func releaseOutside() async throws {
        let h = try await makeHarness()
        let at = try pickUpFirstRow(h)
        let outside = NSPoint(x: 420, y: -60)
        drag(h, from: at, to: outside)
        send(.leftMouseUp, outside, to: h)
        pump(0.3)
        #expect(h.drag.taskID == nil)
        #expect(h.order.last == "A")   // dropped where the placeholder had followed it: the bottom
    }

    @Test("dragging a parent carries its subtree")
    func carriesSubtree() async throws {
        let h = try await makeHarness([("A", 0), ("A1", 1), ("B", 0), ("C", 0), ("D", 0)])
        let at = try pickUpFirstRow(h)
        #expect(h.drag.block.map(\.text) == ["A", "A1"])
        drag(h, from: at, to: NSPoint(x: at.x, y: at.y - 40))
        send(.leftMouseUp, NSPoint(x: at.x, y: at.y - 40), to: h)
        pump(0.3)
        let index = try #require(h.order.firstIndex(of: "A"))
        #expect(index > 0)                       // it moved…
        #expect(h.order[index + 1] == "A1")      // …and its subtask came along, still nested under it
        #expect(h.controller.tasks[index].indentLevel == 0)
        #expect(h.controller.tasks[index + 1].indentLevel == 1)
    }

    #if DEBUG
    @Test("moving within one slot doesn't rebuild the list every frame")
    func noPerFrameListRebuild() async throws {
        let h = try await makeHarness()
        let at = try pickUpFirstRow(h)
        pump(0.3)
        NoteView.taskListRenders = 0
        for i in 1...20 {
            send(.leftMouseDragged, NSPoint(x: at.x + CGFloat(i % 3), y: at.y - CGFloat(i % 4)), to: h)
        }
        #expect(h.drag.location.x != 0)
        #expect(NoteView.taskListRenders < 3, "the list re-rendered \(NoteView.taskListRenders)× for 20 moves")
        send(.leftMouseUp, at, to: h)
        pump(0.3)
    }
    #endif
}
