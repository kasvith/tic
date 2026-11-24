import Foundation
import SwiftUI
import Testing
@testable import Tic

@Suite("NoteWindowManager placement")
struct NoteWindowManagerTests {
    // Two side-by-side displays in global coordinates: the main one at the origin, a second to its right.
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let second = CGRect(x: 1440, y: 0, width: 2560, height: 1415)

    @Test("a note on the second display counts as visible, not lost")
    func secondDisplayIsVisible() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.isVisible(onSecond, onAnyOf: [main, second]))
        #expect(!NoteWindowManager.isVisible(onSecond, onAnyOf: [main]))   // display unplugged
    }

    @Test("a sliver hanging off every edge is lost; an 80×80 corner is enough")
    func slivers() {
        let sliver = CGRect(x: -250, y: 300, width: 280, height: 360)     // 30pt showing
        #expect(!NoteWindowManager.isVisible(sliver, onAnyOf: [main, second]))
        let corner = CGRect(x: -200, y: -280, width: 280, height: 360)    // exactly 80×80 showing
        #expect(NoteWindowManager.isVisible(corner, onAnyOf: [main, second]))
    }

    @Test("office → home → office: parked on the main display while its monitor is gone, back exactly after")
    func displayRoundTrip() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)

        let parked = NoteWindowManager.placement(for: onSecond, screens: [main], main: main)   // monitor unplugged
        #expect(NoteWindowManager.isVisible(parked, onAnyOf: [main]))
        #expect(parked.size == onSecond.size)
        #expect(parked.maxX == main.maxX && parked.minY == 300)   // nearest edge, not a pile in the centre

        // The saved frame is never rewritten by parking, so the same input places it back on the monitor.
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)
    }

    @Test("a note taller than the display keeps its header on screen")
    func tallNote() {
        let tall = CGRect(x: 5000, y: 5000, width: 280, height: 1200)
        let parked = NoteWindowManager.placement(for: tall, screens: [main], main: main)
        #expect(parked.maxY == main.maxY && parked.maxX == main.maxX)
    }

    // MARK: Roll-up (issue 18)

    private let bar = NoteLayout.collapsedHeight

    @Test("mid-screen: rolls up from the top edge and back to the exact frame")
    func rollMidScreen() {
        let note = CGRect(x: 100, y: 300, width: 280, height: 360)
        let rolled = NoteWindowManager.rolledFrame(note, toHeight: bar, screens: [main])
        #expect(rolled.maxY == note.maxY && rolled.height == bar)
        #expect(NoteWindowManager.rolledFrame(rolled, toHeight: note.height, screens: [main]) == note)
    }

    @Test("parked at the bottom: rolls up flush with it and expands upward")
    func rollAtBottom() {
        let note = CGRect(x: 100, y: main.minY + 10, width: 280, height: 360)   // within the snap
        let rolled = NoteWindowManager.rolledFrame(note, toHeight: bar, screens: [main])
        #expect(rolled.minY == main.minY && rolled.height == bar)
        let expanded = NoteWindowManager.rolledFrame(rolled, toHeight: note.height, screens: [main])
        #expect(expanded.minY == main.minY && expanded.height == note.height)
    }

    @Test("a low bar expands upward rather than off the bottom; a tall one keeps its header on screen")
    func expandStaysOnScreen() {
        let low = CGRect(x: 100, y: 100, width: 280, height: bar)   // above the snap, too low for 360
        #expect(NoteWindowManager.rolledFrame(low, toHeight: 360, screens: [main]).minY == main.minY)
        let tall = NoteWindowManager.rolledFrame(low, toHeight: 1200, screens: [main])
        #expect(tall.maxY == main.maxY)
    }

    @Test("a bar let go near the bottom glides down flush; one let go higher up stays put")
    @MainActor func dropSnapsToBottom() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main?.visibleFrame)
        let db = try AppDatabase.makeInMemory()
        let note = Note(isCollapsed: true)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }

        // Where a header drag let go (`NotePanel.performDrag` ends with `onDragEnded`).
        func drop(atHeight y: CGFloat, dragged: Bool = true) {
            panel.setFrameOrigin(NSPoint(x: screen.minX + 100, y: screen.minY + y))
            if dragged { panel.onDragEnded?() }
        }
        // The glide is a 0.22 s animation; with the whole suite running it can take a good deal longer.
        func settles(at y: CGFloat) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while panel.frame.minY != y, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            return panel.frame.minY == y
        }
        drop(atHeight: 30)   // within the snap
        #expect(try await settles(at: screen.minY))
        drop(atHeight: 200)
        try await Task.sleep(for: .milliseconds(400))   // long enough for a glide that shouldn't happen
        #expect(panel.frame.minY == screen.minY + 200)
        drop(atHeight: 30, dragged: false)   // moved, not dragged by the user: left alone
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.frame.minY == screen.minY + 30)
    }

    @Test("the hover controls never resize a bar: only the manager sizes a note (issue 22)")
    @MainActor func hoverLeavesBarSize() async throws {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let note = Note(isCollapsed: true)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }
        // Narrower than the controls, the worst case: they used to raise the content's minimum width, and the
        // hosting view resized the window from inside a layout pass, which AppKit aborts the app for.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 60, height: bar)), display: true)
        try await Task.sleep(for: .milliseconds(100))

        func trackers(in view: NSView) -> [HoverArea.TrackingView] {
            ((view as? HoverArea.TrackingView).map { [$0] } ?? []) + view.subviews.flatMap(trackers)
        }
        let content = try #require(panel.contentView)
        let tracker = try #require(trackers(in: content).first)
        tracker.mouseEntered(with: NSEvent())   // the override only reports it; synthetic events can't drive it
        try await Task.sleep(for: .milliseconds(350))   // the controls' fade-in
        #expect(panel.frame.size == NSSize(width: 60, height: bar))
        #expect(manager.windowWillResize(panel, to: NSSize(width: 40, height: bar)).width == NoteLayout.minWidth)
    }

    @Test("a rolled-up bar is frameless and keeps its height; expanding brings the system frame back")
    @MainActor func barHeightLock() async throws {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let note = Note(isCollapsed: true)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }
        // Frameless: no system corners to split from the fill, and no title-bar safe area.
        #expect(!panel.styleMask.contains(.titled) && panel.contentView?.safeAreaInsets.top == 0)
        #expect(!panel.hasShadow)   // a frameless window's shadow rims the capsule like a dark border
        #expect(manager.windowWillResize(panel, to: NSSize(width: 320, height: 200)) == NSSize(width: 320, height: bar))

        try await db.updateNoteFlags(id: note.id, floatOnTop: false, showOnAllSpaces: false, isCollapsed: false)
        // The DB echo, then an animated roll: wait for it rather than a fixed time (parallel suites slow it).
        for _ in 0..<60 where panel.frame.height <= bar { try await Task.sleep(for: .milliseconds(50)) }
        #expect(panel.frame.height > bar && panel.styleMask.contains(.titled) && panel.hasShadow)
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(manager.windowWillResize(panel, to: NSSize(width: 320, height: 200)) == NSSize(width: 320, height: 200))
        // The content has no minimum height (so it can roll open from a bar): the delegate keeps one.
        let short = manager.windowWillResize(panel, to: NSSize(width: 320, height: 40))
        #expect(short.height == NoteLayout.minExpandedHeight)
    }
}

@MainActor
@Suite("NotePanel window behaviour")
struct NotePanelBehaviorTests {
    @Test("all Spaces applies only while pinned, and then it reaches full-screen apps' Spaces too")
    func allSpacesOnlyWhilePinned() {
        _ = NSApplication.shared
        let panel = NotePanel(note: Note(), content: AnyView(Color.clear))
        for (pinned, everywhere, joins) in [(false, false, false), (false, true, false), (true, false, false), (true, true, true)] {
            panel.apply(floatOnTop: pinned, showOnAllSpaces: everywhere)
            #expect(panel.level == (pinned ? .floating : .normal))
            #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) == joins)
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
    }
}

@MainActor
@Suite("Unpinning over a full-screen app")
struct UnpinOverFullScreenTests {
    @Test("a note let go of all Spaces over a full-screen app hides, and comes back once a desktop shows")
    func hidesThenReturns() async throws {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let note = Note(floatOnTop: true, showOnAllSpaces: true)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }
        var fullScreen = true
        manager.isFullScreenSpace = { _ in fullScreen }

        manager.applyBehavior(panel, floatOnTop: false, showOnAllSpaces: true)   // unpin over full screen
        #expect(!panel.isVisible)
        manager.activeSpaceDidChange()                                            // another full-screen app
        #expect(!panel.isVisible)
        fullScreen = false
        manager.activeSpaceDidChange()                                            // a desktop
        #expect(panel.isVisible)
    }

    @Test("on a desktop, unpinning leaves the note where it is; pinning again shows a hidden note")
    func desktopAndRepin() async throws {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let note = Note(floatOnTop: true, showOnAllSpaces: true)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }
        var fullScreen = false
        manager.isFullScreenSpace = { _ in fullScreen }

        manager.applyBehavior(panel, floatOnTop: false, showOnAllSpaces: true)   // unpin on a desktop
        #expect(panel.isVisible)

        manager.applyBehavior(panel, floatOnTop: true, showOnAllSpaces: true)
        fullScreen = true
        manager.applyBehavior(panel, floatOnTop: true, showOnAllSpaces: false)   // switch off over full screen
        #expect(!panel.isVisible)
        manager.applyBehavior(panel, floatOnTop: true, showOnAllSpaces: true)    // an agent turns it back on
        #expect(panel.isVisible)
    }
}

@MainActor
@Suite("Private lists")
struct PrivateListTests {
    @Test("a private list's window stays out of captures, and Settings can make every list private")
    func sharingAndCover() async throws {
        _ = NSApplication.shared
        let db = try AppDatabase.makeInMemory()
        let secret = Note(title: "Salary talk", isPrivate: true)
        let open = Note(title: "Groceries")
        try await db.insert(secret)
        try await db.insert(open)
        let manager = NoteWindowManager(appDatabase: db)
        let secretPanel = manager.openNote(secret, makeKey: false)
        let openPanel = manager.openNote(open, makeKey: false)
        defer { secretPanel.close(); openPanel.close() }

        #expect(secretPanel.sharingType == .none)
        #expect(openPanel.sharingType == .readOnly)

        manager.everyListPrivate = true
        #expect(openPanel.sharingType == .none)
        manager.everyListPrivate = false
        #expect(openPanel.sharingType == .readOnly)
    }
}

@MainActor
@Suite("Edge dock")
struct EdgeDockTests {
    /// A point on an outer edge of one of this Mac's displays (nil if every edge is a seam).
    private func outerEdge() -> (pointer: CGPoint, edge: DockEdge, display: DockLayout.Display)? {
        for display in NoteWindowManager.displays {
            let mid = display.frame.midY
            for x in [display.frame.minX + 1, display.frame.maxX - 1] {
                if let hit = DockLayout.edge(at: CGPoint(x: x, y: mid), in: NoteWindowManager.displays) {
                    return (CGPoint(x: x, y: mid), hit.edge, hit.display)
                }
            }
        }
        return nil
    }

    @Test("dragging a note to an outer edge folds it into a tab; pulling it out unfolds it, full size, where it's let go")
    func dockAndUndockByDrag() async throws {
        _ = NSApplication.shared
        guard let target = outerEdge() else { return }
        let db = try AppDatabase.makeInMemory()
        let display = target.display.visible
        let note = Note(title: "Groceries", frameX: display.midX - 140, frameY: display.midY - 180, frameW: 280, frameH: 360)
        try await db.insert(note)
        let manager = NoteWindowManager(appDatabase: db)
        let panel = manager.openNote(note, makeKey: false)
        defer { panel.close() }

        // Drag the header to the edge: the note folds into its tab there, frameless.
        let folded = try #require(panel.onDragMove?(target.pointer, panel.frame))
        #expect(folded.width == DockLayout.maxTabWidth)
        #expect(target.edge == .left ? folded.minX == display.minX : folded.maxX == display.maxX)
        #expect(!panel.styleMask.contains(.titled))
        panel.setFrame(folded, display: false)
        panel.onDragEnded?()
        #expect(panel.frame.width <= DockLayout.maxTabWidth)
        try await waitFor { try await db.note(id: note.id)?.dockEdge == target.edge }

        // Pull it back out to the middle: the note unfolds at its own size, with its frame back.
        let middle = CGPoint(x: display.midX, y: display.midY)
        let unfolded = try #require(panel.onDragMove?(middle, panel.frame))
        #expect(unfolded.size == CGSize(width: 280, height: 360))
        #expect(panel.styleMask.contains(.titled))
        panel.setFrame(unfolded, display: false)
        panel.onDragEnded?()
        try await waitFor { try await db.note(id: note.id)?.dockEdge == nil }
    }

    /// Under the whole suite's load a database write can take over a second, so this waits up to 10.
    private func waitFor(_ condition: @escaping () async throws -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out")
    }
}
