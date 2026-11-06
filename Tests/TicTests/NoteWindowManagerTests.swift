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
        func drop(atHeight y: CGFloat, dragged: Bool = true) async throws {
            panel.setFrameOrigin(NSPoint(x: screen.minX + 100, y: screen.minY + y))
            if dragged { panel.onDragEnded?() }
            try await Task.sleep(for: .milliseconds(400))   // the whole glide: rounded to points, it lands early
        }
        try await drop(atHeight: 30)   // within the snap
        #expect(panel.frame.minY == screen.minY)
        try await drop(atHeight: 200)
        #expect(panel.frame.minY == screen.minY + 200)
        try await drop(atHeight: 30, dragged: false)   // moved, not dragged by the user: left alone
        #expect(panel.frame.minY == screen.minY + 30)
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
        // Frameless: no system corners to split from the fill, and no title-bar safe area — the hosting view
        // grows the window to the bar's minimum height plus that inset, which bounced a titled bar to ~47pt.
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
