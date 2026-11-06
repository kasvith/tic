import AppKit
import SwiftUI

/// Owns the live `NotePanel`s — one per note — and keeps their on-screen frames in sync with
/// the database. Acts as each panel's window delegate.
@MainActor
final class NoteWindowManager: NSObject, NSWindowDelegate {
    private let appDatabase: AppDatabase
    private var panels: [UUID: NotePanel] = [:]
    private var controllers: [UUID: NoteController] = [:]
    private var pendingFrameSaves: [UUID: Task<Void, Never>] = [:]
    /// Height a note had before it was rolled up, so it restores to the right size on expand.
    private var expandedHeights: [UUID: CGFloat] = [:]
    /// Each open note's frame as saved in the DB — the last spot the user chose. Only user drags and
    /// resizes update it; a placement we or macOS make (display unplugged, launch rescue) never does,
    /// so a note parked on the laptop at home still returns to its monitor at the office.
    private var savedFrames: [UUID: CGRect] = [:]
    /// True while `place` moves a panel, so its own `windowDidMove` isn't persisted.
    private var placing = false
    /// Frame saves are dropped until this instant after a display change: macOS moves windows off a
    /// vanished display at about the same time as the notification, in either order.
    private var suppressSavesUntil = Date.distantPast
    /// The one image window, reused for whichever image was opened last.
    private var imageWindow: NSWindow?
    /// The note whose image the image window is showing, so closing that note closes it too.
    private var imageWindowNoteID: UUID?

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: - Opening notes

    /// Opens a floating panel for every note that was on screen at last quit (called at launch).
    func restoreAll() async {
        do {
            let notes = try await appDatabase.openNotes()
            for note in notes { openNote(note, makeKey: false) }   // launch: show, don't steal focus
            NSLog("[Tic] restored \(notes.count) note panel(s)")
        } catch {
            NSLog("[Tic] restoreAll failed: \(error)")
        }
    }

    /// Shows the panel for a note, creating it if necessary. `makeKey` brings it to key (so an
    /// interactive open from the menu bar focuses the note and dismisses the .window popover);
    /// pass `false` for launch restore so we don't yank focus.
    @discardableResult
    func openNote(_ note: Note, makeKey: Bool = true) -> NotePanel {
        if let existing = panels[note.id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        if !note.isOpen {
            Task { [appDatabase] in try? await appDatabase.updateNoteOpen(id: note.id, isOpen: true) }
        }
        let controller = NoteController(note: note, database: appDatabase)
        controllers[note.id] = controller
        controller.start()

        let panel = NotePanel(note: note, content: AnyView(NoteView(controller: controller)))
        panels[note.id] = panel
        savedFrames[note.id] = CGRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak panel] floatOnTop, showOnAllSpaces in
            panel?.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
        }
        controller.onClose = { [weak panel, appDatabase] in
            // Only the user's X marks a note closed (quit doesn't), so launch restores what was visible.
            Task { try? await appDatabase.updateNoteOpen(id: note.id, isOpen: false) }
            panel?.close()   // triggers windowWillClose → teardown; does NOT delete the note
        }
        controller.onSetCollapsed = { [weak self, weak panel] collapsed in
            guard let self, let panel else { return }
            self.setCollapsed(panel, collapsed: collapsed, animate: true)
        }
        controller.onNewNote = { [weak self] in
            Task { await self?.newNote() }
        }
        controller.onOpenImage = { [weak self, weak controller, weak panel] taskId in
            guard let self, let controller, let panel else { return }
            self.showImageWindow(controller: controller, taskId: taskId, from: panel)
        }
        panel.onPasteImage = { [weak controller] data in
            controller?.stageImage(data)
        }
        panel.onDragEnded = { [weak self, weak panel] in
            if let panel { self?.snapToBottom(panel) }
        }

        place(panel)
        if makeKey {
            panel.makeKeyAndOrderFront(nil)   // become key → the menu bar popover resigns/dismisses
        } else {
            panel.orderFront(nil)
        }

        // A note saved in the rolled-up state opens rolled up (keeping its expanded height).
        if note.isCollapsed {
            setCollapsed(panel, collapsed: true, animate: false)
        }
        panel.delegate = self   // only now: the placement and roll-up above aren't user moves to persist
        return panel
    }

    /// Creates a fresh note (cascaded so it doesn't sit exactly on top of the last) and opens it.
    /// The DB assigns a unique, monotonic `sortIndex`; the cascade offset derives from that index
    /// (not the open-panel count), so placement and ordering stay stable after closes/deletes.
    func newNote() async {
        do {
            let inserted = try await appDatabase.insertNewNote(
                Note(color: NoteColor.allCases.randomElement() ?? .yellow)
            )
            let step = Double(inserted.sortIndex % 8) * 28
            var note = inserted
            note.frameX = 180 + step
            note.frameY = 320 - step
            try? await appDatabase.updateNoteFrame(
                id: note.id, x: note.frameX, y: note.frameY,
                width: note.frameW, height: note.frameH
            )
            openNote(note)
            controllers[note.id]?.requestRename()   // a new list starts with its name being typed
        } catch {
            NSLog("[Tic] newNote failed: \(error)")
        }
    }

    /// Brings every open note to the front (menu-bar "Show All").
    func showAll() {
        for panel in panels.values { panel.orderFront(nil) }
    }

    /// Permanently deletes a note: closes its window if open (existing teardown), then removes
    /// the row (its tasks go with it via the FK cascade).
    func deleteNote(_ note: Note) async {
        do {
            try await appDatabase.deleteNote(id: note.id)
            panels[note.id]?.close()   // only tear down once the row is actually gone
        } catch {
            NSLog("[Tic] deleteNote failed: \(error)")
        }
    }

    /// Rolls a panel up to just its title bar (or back to its expanded height), from the edge
    /// `rolledFrame` picks. While collapsed the height is locked (`windowWillResize`).
    private func setCollapsed(_ panel: NotePanel, collapsed: Bool, animate: Bool) {
        let id = panel.noteID
        let current = panel.frame
        let targetHeight: CGFloat
        if collapsed {
            if current.height > NoteLayout.collapsedHeight { expandedHeights[id] = current.height }
            targetHeight = NoteLayout.collapsedHeight
        } else {
            targetHeight = expandedHeights[id] ?? max(current.height, 240)
            expandedHeights[id] = nil
        }
        let newFrame = Self.rolledFrame(current, toHeight: targetHeight, screens: Self.visibleFrames)
        if collapsed { panel.makeFirstResponder(nil) }   // end any edit: the title stays visible in the bar
        // The system frame (shadow, corners) tracks a resizing window, so it comes back before expanding and
        // goes only once the bar is down to size.
        if !collapsed { panel.setRolledUp(false) }
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let panel, self?.controllers[id]?.note.isCollapsed == true else { return }   // not re-expanded
            panel.setRolledUp(true)
        }
        guard animate else {
            panel.setFrame(newFrame, display: true)
            finish()
            return
        }
        // Not `setFrame(_:display:animate:)`: that blocks, so SwiftUI swapped the bar for the note only
        // once the window was already full height. The animator runs on the run loop, alongside the
        // view, which drops its list once the window is down to the bar (`NoteView.showsBar`).
        // ponytail: a re-toggle mid-roll remembers the in-between height; track the target if that bites.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.rollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    private static let rollDuration: TimeInterval = 0.22

    private static var visibleFrames: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    /// Puts a panel where its saved frame says, as long as some connected display shows it; otherwise
    /// parks it on the main display (nearest edge, same size). Runs at open and on every display
    /// change, so unplugging a monitor parks its notes and plugging it back returns them to the exact
    /// spot. Frames are global coordinates spanning all displays (as Stickies stores them), and this
    /// never persists: the saved frame stays the user's.
    private func place(_ panel: NotePanel) {
        guard let saved = savedFrames[panel.noteID], let main = NSScreen.main else { return }
        let screens = Self.visibleFrames
        let target = Self.placement(for: saved, screens: screens, main: main.visibleFrame)
        // Keep the live size: a rolled-up note sits where rolling up from `target` would put it.
        let height = panel.frame.height
        let frame = height < target.height ? Self.rolledFrame(target, toHeight: height, screens: screens) : target
        placing = true
        panel.setFrameOrigin(frame.origin)
        placing = false
    }

    /// A display was plugged in, unplugged, or rearranged. macOS shoves windows off a vanished display
    /// onto a remaining one, which must not be saved as the user's choice: drop the moves it caused
    /// (already pending or still to come) and re-place every note from its saved frame.
    @objc private func screensDidChange() {
        // ponytail: a 2s blanket, since macOS moves windows within the same reconfiguration; a user drag
        // inside it is dropped — make it precise if that ever shows.
        suppressSavesUntil = Date().addingTimeInterval(2)
        for task in pendingFrameSaves.values { task.cancel() }
        pendingFrameSaves.removeAll()
        for panel in panels.values { place(panel) }
    }

    // MARK: - Image window

    /// Shows a task's image in the image window, creating the window on first use. It takes the note's
    /// window level, so it opens above a float-on-top note, and activates the app so it comes up in front
    /// (notes are non-activating panels).
    private func showImageWindow(controller: NoteController, taskId: UUID, from panel: NotePanel) {
        let window = imageWindow ?? ImageWindow()
        imageWindow = window
        imageWindowNoteID = controller.noteID
        let text = controller.tasks.first(where: { $0.id == taskId })?.text ?? ""
        window.title = text.split(separator: "\n").first.map(String.init) ?? "Image"
        window.contentView = NSHostingView(
            rootView: ImageViewer(controller: controller, taskId: taskId) { [weak window] in window?.close() }
        )
        window.level = panel.level
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var openCount: Int { panels.count }

    // MARK: - Actions for external writers (MCP)

    /// Surfaces a note's panel, opening it from the DB if it wasn't on screen. Used when an agent
    /// creates a note or writes to a closed one — so the user sees the work. Uses
    /// `orderFrontRegardless` so a `.normal`-level note appears above other apps even while Tic is in
    /// the background, but does **not** activate Tic — the user's keyboard focus stays where it was.
    func openNoteByID(_ id: UUID) async {
        if let panel = panels[id] { panel.orderFrontRegardless(); return }
        guard let note = try? await appDatabase.note(id: id) else { return }
        let panel = openNote(note, makeKey: false)
        panel.orderFrontRegardless()
    }

    /// Brings a note fully to the foreground: activates Tic and makes the note key, so it lands in
    /// front and ready to type in. The explicit "jump to this note" (the `focus_note` MCP tool),
    /// stronger than `openNoteByID` — this one does take focus.
    func focusNoteByID(_ id: UUID) async {
        let panel: NotePanel
        if let existing = panels[id] {
            panel = existing
        } else if let note = try? await appDatabase.note(id: id) {
            panel = openNote(note, makeKey: false)
        } else {
            return
        }
        // A background app's plain activate() is refused by macOS focus-stealing prevention, so use
        // the assertive form (deprecated on 14 but still the only thing that reliably pulls focus
        // forward from another app). This is opt-in (focus_note / focus:true), never a plain write.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Hides a note's panel (the agent equivalent of the header X): marks it closed and closes the
    /// window if it's open. A no-op beyond the DB write when nothing is on screen.
    func closeNoteByID(_ id: UUID) async {
        try? await appDatabase.updateNoteOpen(id: id, isOpen: false)
        panels[id]?.close()   // → windowWillClose tears down the controller/panel
    }

    /// Moves/resizes a note. If its panel is live, set the frame (the debounced save persists it,
    /// exactly like a user drag); otherwise persist the frame so `place` uses it when next opened.
    func setFrame(_ id: UUID, to rect: CGRect) async {
        if let panel = panels[id] {
            panel.setFrame(rect, display: true, animate: false)   // fires didMove/didResize → save
        } else {
            savedFrames[id] = rect
            try? await appDatabase.updateNoteFrame(
                id: id, x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height
            )
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification) }

    /// The note's height limits, for user resizes only (the hosting view resets `minSize`, and a roll
    /// animation doesn't come through here). A rolled-up bar resizes only sideways, so it can't be dragged
    /// into a sliver or a blank note; an open note keeps room for its header and quick-add.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let panel = sender as? NotePanel else { return frameSize }
        let collapsed = controllers[panel.noteID]?.note.isCollapsed == true
        let height = collapsed ? NoteLayout.collapsedHeight : max(frameSize.height, NoteLayout.minExpandedHeight)
        return NSSize(width: frameSize.width, height: height)
    }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        if imageWindowNoteID == panel.noteID { imageWindow?.close() }
        pendingFrameSaves[panel.noteID]?.cancel()
        pendingFrameSaves[panel.noteID] = nil
        expandedHeights[panel.noteID] = nil
        savedFrames[panel.noteID] = nil
        controllers[panel.noteID]?.stop()
        controllers[panel.noteID] = nil
        panels[panel.noteID] = nil
    }

    /// Debounced frame persistence — drag/resize fire continuously, so we save only after the
    /// gesture settles (300ms idle).
    private func scheduleFrameSave(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        // Not a user move: our own placement, or macOS relocating windows around a display change.
        if placing || Date() < suppressSavesUntil { return }
        let id = panel.noteID
        let live = panel.frame

        // While rolled up, the window is at its collapsed height. Still persist position/width, but
        // save the frame expanding from here would give (EXPANDED height) — otherwise a move/resize
        // done while collapsed is lost on relaunch, where rolling up from it puts the bar back.
        let collapsed = controllers[id]?.note.isCollapsed == true
        let frame = collapsed
            ? Self.rolledFrame(live, toHeight: expandedHeights[id] ?? live.height, screens: Self.visibleFrames)
            : live
        let (x, y, width, height) = (frame.minX, frame.minY, frame.width, frame.height)
        savedFrames[id] = frame

        pendingFrameSaves[id]?.cancel()
        pendingFrameSaves[id] = Task { [appDatabase] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            try? await appDatabase.updateNoteFrame(id: id, x: x, y: y, width: width, height: height)
        }
    }
}

// MARK: - Bottom snap

extension NoteWindowManager {
    /// A bar let go within `bottomSnap` of its display's bottom (or past it) glides down flush, where
    /// expanding grows upward (issue 18). "Rolling" it to its own height is exactly that move.
    private func snapToBottom(_ panel: NotePanel) {
        guard controllers[panel.noteID]?.note.isCollapsed == true else { return }
        let snapped = Self.rolledFrame(panel.frame, toHeight: panel.frame.height, screens: Self.visibleFrames)
        guard snapped != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.rollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(snapped, display: true)
        }
    }
}

// MARK: - Frame geometry (pure, tested)

extension NoteWindowManager {
    /// How far above the bottom of the display (the Dock's top) a note still counts as parked there.
    nonisolated static let bottomSnap: CGFloat = 48

    /// `frame` rolled up to `height` or back down. The top edge stays put, unless the note's bottom is
    /// within `bottomSnap` of its display's bottom: then it rolls from there, flush — a bar parked above
    /// the Dock stays there and expands upward. Expanding never runs off the bottom or above the top.
    nonisolated static func rolledFrame(_ frame: CGRect, toHeight height: CGFloat, screens: [CGRect]) -> CGRect {
        var result = frame
        result.origin.y = frame.maxY - height
        result.size.height = height
        let area = { (s: CGRect) in s.intersection(frame).width * s.intersection(frame).height }
        guard let screen = screens.max(by: { area($0) < area($1) }), area(screen) > 0 else { return result }
        if frame.minY <= screen.minY + bottomSnap { result.origin.y = screen.minY }
        result.origin.y = min(max(result.origin.y, screen.minY), screen.maxY - height)
        return result
    }

    /// `saved` itself when at least an 80×80 corner lies on one of `screens`; else `saved` shifted the
    /// shortest distance that fits it on `main` (a note taller than the screen keeps its top edge on).
    nonisolated static func placement(for saved: CGRect, screens: [CGRect], main: CGRect) -> CGRect {
        if isVisible(saved, onAnyOf: screens) { return saved }
        var frame = saved
        frame.origin.x = min(max(saved.minX, main.minX), main.maxX - saved.width)
        frame.origin.y = min(max(saved.minY, main.minY), main.maxY - saved.height)
        return frame
    }

    /// True when at least an 80×80 corner of `frame` lies on one of `screens` (enough to grab).
    nonisolated static func isVisible(_ frame: CGRect, onAnyOf screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= 80 && overlap.height >= 80
        }
    }
}
