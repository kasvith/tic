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

    /// Settings › Treat every list as private.
    var everyListPrivate = false { didSet { applyPrivacyToAll() } }
    /// Private lists are covered while the screen is shared (menu bar › Cover Private Lists).
    var coveringPrivate = false { didSet { applyPrivacyToAll() } }

    /// How docked tabs look (Settings › General › Docked tabs).
    var dockTabStyle: DockTabStyle = .titleCount {
        didSet {
            for controller in controllers.values { controller.dockTabStyle = dockTabStyle }
            layoutTabs()
        }
    }
    /// Settings › Show tabs over full-screen apps: docked tabs join every Space.
    var tabsOverFullScreen = false {
        didSet { for id in dockEdges.keys { reapplyBehavior(id) } }
    }

    // Edge dock state (`MARK: - Edge dock`).
    /// Docked notes and their edge: the window logic's own record, since the note row can lag its observation.
    private var dockEdges: [UUID: DockEdge] = [:]
    /// Where each docked note's tab sits (after stacking).
    private var tabFrames: [UUID: CGRect] = [:]
    /// Docked notes peeking out, and whether a click is keeping them out.
    private var peeks: [UUID: Bool] = [:]
    private var peekTimers: [UUID: Task<Void, Never>] = [:]
    private var pointerInside: Set<UUID> = []
    /// A drag in progress: whether it started on a tab, and where it would dock if let go now.
    private var drags: [UUID: Drag] = [:]
    private struct Drag {
        var fromTab: Bool
        var target: (edge: DockEdge, tab: CGRect)?
    }
    /// The edge the pointer is at: its tabs come in front of other windows, and go back 0.4 s after it leaves.
    private var hotEdge: (edge: DockEdge, display: DockLayout.Display)?
    private var lowerTask: Task<Void, Never>?
    /// Mouse-moved monitors, installed only while a note is docked.
    private var mouseMonitors: [Any] = []

    /// Notes let go of all Spaces while their display showed a full-screen app: hidden until it shows a desktop.
    private var parked: Set<UUID> = []
    /// Whether a display is showing an app's full-screen Space. Swapped in tests.
    var isFullScreenSpace: @MainActor (NSScreen?) -> Bool = { screen in screen.map(SkyLight.isFullScreen) ?? false }

    /// Sync between Macs, handed to each note's views (its header shows sync activity and Sync Now). Nil
    /// in tests, where notes simply never show sync.
    var sync: FolderSync?

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    /// Applies pin + all Spaces to a live note. macOS keeps a window on whichever Space is active when it stops
    /// joining all Spaces, and no collection behaviour or re-ordering moves it off later (probed, Nov 2026). So a
    /// note let go over a full-screen app is hidden until its display shows a desktop again, and lands there.
    func applyBehavior(_ panel: NotePanel, floatOnTop: Bool, showOnAllSpaces: Bool) {
        let id = panel.noteID
        let wasEverywhere = panel.collectionBehavior.contains(.canJoinAllSpaces)
        panel.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces,
                    tabOnAllSpaces: dockEdges[id] != nil && tabsOverFullScreen)
        if peeks[id] != nil || isRaised(id) { panel.level = .floating }   // a peek or a pointed-at tab stays in front
        let isEverywhere = panel.collectionBehavior.contains(.canJoinAllSpaces)
        if isEverywhere, parked.remove(panel.noteID) != nil {
            panel.orderFrontRegardless()   // pinned everywhere again (by an agent) while hidden
        } else if wasEverywhere, !isEverywhere, isFullScreenSpace(Self.screen(of: panel)) {
            panel.orderOut(nil)
            parked.insert(panel.noteID)
        }
    }

    private func applyPrivacyToAll() {
        for id in panels.keys { applyPrivacy(id) }
    }

    /// A private list's window is left out of screen captures that honour `sharingType` (older capture paths;
    /// ScreenCaptureKit on macOS 15.4+ is reported not to), and drawn as a cover while `coveringPrivate`.
    private func applyPrivacy(_ id: UUID) {
        guard let panel = panels[id], let controller = controllers[id] else { return }
        controller.everyListPrivate = everyListPrivate
        controller.coveringPrivate = coveringPrivate
        panel.sharingType = controller.isPrivate ? .none : .readOnly
        if imageWindowNoteID == id { imageWindow?.sharingType = panel.sharingType }
    }

    /// The user moved to another Space: show each parked note whose display is on a desktop now.
    @objc func activeSpaceDidChange() {
        for id in parked {
            guard let panel = panels[id] else { parked.remove(id); continue }
            if isFullScreenSpace(Self.screen(of: panel)) { continue }
            parked.remove(id)
            panel.orderFrontRegardless()
        }
    }

    /// The display a note is on. A hidden window has no `screen`, so fall back to the one its frame is on.
    private static func screen(of panel: NSWindow) -> NSScreen? {
        panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
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
            if dockEdges[note.id] != nil { peek(note.id, keep: true) } else { existing.makeKeyAndOrderFront(nil) }
            return existing
        }
        if !note.isOpen {
            Task { [appDatabase] in try? await appDatabase.updateNoteOpen(id: note.id, isOpen: true) }
        }
        let controller = NoteController(note: note, database: appDatabase)
        controllers[note.id] = controller
        controller.start()

        let panel = NotePanel(note: note, content: AnyView(NoteView(controller: controller).environment(sync)))
        panels[note.id] = panel
        savedFrames[note.id] = CGRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak self, weak panel] floatOnTop, showOnAllSpaces in
            guard let self, let panel else { return }
            self.applyBehavior(panel, floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
        }
        controller.onClose = { [weak panel, appDatabase] in
            // Only the user's X marks a note closed (quit doesn't), so launch restores what was visible.
            Task { try? await appDatabase.updateNoteOpen(id: note.id, isOpen: false) }
            panel?.close()   // triggers windowWillClose → teardown; does NOT delete the note
        }
        controller.onSetCollapsed = { [weak self, weak panel] collapsed in
            guard let self, let panel, self.dockEdges[note.id] == nil else { return }   // docked: applies on undock
            self.setCollapsed(panel, collapsed: collapsed, animate: true)
        }
        controller.dockTabStyle = dockTabStyle
        controller.onPointerInside = { [weak self] inside in self?.pointerMoved(note.id, inside: inside) }
        controller.onTabClick = { [weak self] in self?.peek(note.id, keep: true) }
        controller.onToggleDock = { [weak self] in self?.toggleDock(note.id) }
        controller.onNewNote = { [weak self] in
            Task { await self?.newNote() }
        }
        controller.onPrivacyChange = { [weak self] in self?.applyPrivacy(note.id) }
        controller.onOpenImage = { [weak self, weak controller, weak panel] taskId in
            guard let self, let controller, let panel else { return }
            self.showImageWindow(controller: controller, taskId: taskId, from: panel)
        }
        panel.onPasteImage = { [weak controller] data in
            controller?.stageImage(data)
        }
        panel.onDragMove = { [weak self, weak panel] pointer, proposed in
            guard let self, let panel else { return proposed }
            return self.dragMoved(panel, pointer: pointer, proposed: proposed)
        }
        panel.onDragEnded = { [weak self, weak panel] in
            if let panel { self?.dragEnded(panel) }
        }

        applyPrivacy(note.id)
        if let edge = note.dockEdge {
            // A docked note opens as its tab. Rolled up, it keeps its expanded height for peeks and undocking.
            dockEdges[note.id] = edge
            controller.isDocked = true
            controller.tabEdge = edge
            if note.isCollapsed { expandedHeights[note.id] = note.frameH }
            panel.setFrameless(true)
            layoutTabs(animate: false)
            reapplyBehavior(note.id)
            updateMouseMonitors()
        } else {
            place(panel)
        }
        if makeKey {
            panel.makeKeyAndOrderFront(nil)   // become key → the menu bar popover resigns/dismisses
        } else {
            panel.orderFront(nil)
        }

        // A note saved in the rolled-up state opens rolled up (keeping its expanded height).
        if note.isCollapsed && note.dockEdge == nil {
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
        if !collapsed { panel.setFrameless(false) }
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let panel, self?.controllers[id]?.note.isCollapsed == true else { return }   // not re-expanded
            panel.setFrameless(true)
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
        guard dockEdges[panel.noteID] == nil else { return }   // tabs are placed by `layoutTabs`
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
        layoutTabs(animate: false)
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
        window.sharingType = panel.sharingType   // a private list's picture stays out of shares too
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

    /// The note's size limits, for user resizes only (a roll animation doesn't come through here). A
    /// rolled-up bar resizes only sideways, so it can't be dragged into a sliver or a blank note; an open
    /// note keeps room for its header and quick-add.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let panel = sender as? NotePanel else { return frameSize }
        let id = panel.noteID
        if dockEdges[id] != nil && peeks[id] == nil { return sender.frame.size }   // a tab's size is the manager's
        let collapsed = controllers[id]?.note.isCollapsed == true && dockEdges[id] == nil
        let height = collapsed ? NoteLayout.collapsedHeight : max(frameSize.height, NoteLayout.minExpandedHeight)
        return NSSize(width: max(frameSize.width, NoteLayout.minWidth), height: height)
    }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        if imageWindowNoteID == panel.noteID { imageWindow?.close() }
        pendingFrameSaves[panel.noteID]?.cancel()
        pendingFrameSaves[panel.noteID] = nil
        expandedHeights[panel.noteID] = nil
        savedFrames[panel.noteID] = nil
        parked.remove(panel.noteID)
        let wasDocked = dockEdges.removeValue(forKey: panel.noteID) != nil
        tabFrames[panel.noteID] = nil
        peeks[panel.noteID] = nil
        peekTimers.removeValue(forKey: panel.noteID)?.cancel()
        drags[panel.noteID] = nil
        pointerInside.remove(panel.noteID)
        controllers[panel.noteID]?.stop()
        controllers[panel.noteID] = nil
        panels[panel.noteID] = nil
        if wasDocked {
            layoutTabs()
            updateMouseMonitors()
        }
    }

    /// A click into a peeking note keeps it out (until it loses the keyboard).
    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel, peeks[panel.noteID] != nil else { return }
        peeks[panel.noteID] = true
        peekTimers.removeValue(forKey: panel.noteID)?.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel, peeks[panel.noteID] == true else { return }
        peeks[panel.noteID] = false
        scheduleRetract(panel.noteID)
    }

    /// Debounced frame persistence — drag/resize fire continuously, so we save only after the
    /// gesture settles (300ms idle).
    private func scheduleFrameSave(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        scheduleFrameSave(panel)
    }

    private func scheduleFrameSave(_ panel: NotePanel) {
        // Not a user move: our own placement, or macOS relocating windows around a display change.
        if placing || Date() < suppressSavesUntil { return }
        let id = panel.noteID
        // A drag saves once, when it's let go; a tab's frame is the manager's (the saved one is its peek).
        if drags[id] != nil || (dockEdges[id] != nil && peeks[id] == nil) { return }
        let live = panel.frame

        // While rolled up, the window is at its collapsed height. Still persist position/width, but
        // save the frame expanding from here would give (EXPANDED height) — otherwise a move/resize
        // done while collapsed is lost on relaunch, where rolling up from it puts the bar back.
        let collapsed = controllers[id]?.note.isCollapsed == true && dockEdges[id] == nil
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

// MARK: - Edge dock

extension NoteWindowManager {
    static var displays: [DockLayout.Display] {
        NSScreen.screens.map { DockLayout.Display(frame: $0.frame, visible: $0.visibleFrame) }
    }

    /// The note's own size: what it peeks at and unfolds to (its saved frame; expanded if it's rolled up).
    private func noteSize(_ id: UUID) -> CGSize {
        let saved = savedFrames[id] ?? .zero
        return CGSize(width: max(saved.width, NoteLayout.minWidth), height: max(saved.height, NoteLayout.minExpandedHeight))
    }

    /// A tab's size: a sliver, or long enough for the sideways title (plus icon and count).
    /// ponytail: measured when tabs are laid out (dock, peek back, launch, style change), so a title an agent
    /// renames while the note is a tab truncates until then.
    private func tabSize(_ id: UUID) -> CGSize {
        guard dockTabStyle != .sliver, let controller = controllers[id] else {
            return CGSize(width: DockLayout.sliverWidth, height: 64)
        }
        let note = controller.note
        let title = controller.isCovered ? "Private" : (note.title.isEmpty ? "Untitled List" : note.title)
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        var extra: CGFloat = 26
        if !controller.isCovered, NoteIcon(stored: note.icon) != nil { extra += 19 }
        if dockTabStyle == .titleCount { extra += 21 }
        return CGSize(width: DockLayout.maxTabWidth, height: min(max(width + extra, 64), 220))
    }

    private func reapplyBehavior(_ id: UUID) {
        guard let panel = panels[id], let note = controllers[id]?.note else { return }
        applyBehavior(panel, floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Places every docked note's tab: at its saved top on its edge (of its display, or the main one if that
    /// was unplugged), moved apart where tabs would overlap. Peeking and dragged notes keep their frames.
    private func layoutTabs(animate: Bool = true) {
        let displays = Self.displays
        var groups: [String: (visible: CGRect, tabs: [(id: UUID, frame: CGRect)])] = [:]
        for (id, edge) in dockEdges {
            guard let saved = savedFrames[id], let display = DockLayout.display(for: saved, in: displays) else { continue }
            let key = "\(edge.rawValue) \(display.frame)"
            let tab = DockLayout.tabFrame(edge, top: saved.maxY, size: tabSize(id), in: display.visible)
            groups[key, default: (display.visible, [])].tabs.append((id, tab))
        }
        for group in groups.values {
            for (tab, frame) in zip(group.tabs, DockLayout.stacked(group.tabs.map(\.frame), in: group.visible)) {
                tabFrames[tab.id] = frame
            }
        }
        for (id, frame) in tabFrames where dockEdges[id] != nil && peeks[id] == nil && drags[id] == nil {
            guard let panel = panels[id], panel.frame != frame else { continue }
            setTabFrame(panel, frame, animate: animate)
        }
    }

    /// Shrinks a panel to its tab; the system frame goes once it's down to size (as a roll-up's does).
    private func setTabFrame(_ panel: NotePanel, _ frame: CGRect, animate: Bool) {
        let id = panel.noteID
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let self, let panel, self.dockEdges[id] != nil, self.peeks[id] == nil else { return }
            panel.setFrameless(true)
            self.reapplyBehavior(id)
        }
        guard animate else {
            panel.setFrame(frame, display: true)
            return finish()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.rollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    // MARK: Peek

    /// Slides a docked note out of its tab at full size. `keep` (a click, or opening it from the menu) holds
    /// it out until it loses the keyboard; a hover-peek goes back once the pointer leaves.
    private func peek(_ id: UUID, keep: Bool) {
        guard let edge = dockEdges[id], let panel = panels[id], let tab = tabFrames[id],
              let display = DockLayout.display(for: tab, in: Self.displays) else { return }
        peekTimers.removeValue(forKey: id)?.cancel()
        let wasPeeking = peeks[id] != nil
        peeks[id] = (peeks[id] ?? false) || keep
        panel.level = .floating
        if keep {
            panel.shieldClicksUntil = .distantPast
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        guard !wasPeeking else { return }
        if !keep {
            panel.shieldClicksUntil = Date().addingTimeInterval(0.35)
            panel.onShieldedClick = { [weak self] in self?.peek(id, keep: true) }
        }
        let frame = DockLayout.peekFrame(edge, tab: tab, size: noteSize(id), in: display.visible)
        panel.setFrameless(false)   // the system frame tracks a growing window, so it comes back first
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.rollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Back into the tab.
    private func retract(_ id: UUID) {
        peekTimers.removeValue(forKey: id)?.cancel()
        guard peeks.removeValue(forKey: id) != nil, let panel = panels[id] else { return }
        if panel.isKeyWindow { panel.makeFirstResponder(nil) }   // end any edit; the field goes with the note
        layoutTabs()
    }

    private func scheduleRetract(_ id: UUID) {
        guard peeks[id] == false, !pointerInside.contains(id) else { return }   // a click is keeping it out
        if panels[id]?.childWindows?.contains(where: \.isVisible) == true { return }   // its ⋯ menu is open
        peekTimers[id]?.cancel()
        peekTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.retract(id)
        }
    }

    /// The pointer entered or left a note's window: a tab peeks after 0.15 s on it, a peek goes back 0.4 s
    /// after it leaves.
    private func pointerMoved(_ id: UUID, inside: Bool) {
        if inside { pointerInside.insert(id) } else { pointerInside.remove(id) }
        guard dockEdges[id] != nil, drags[id] == nil else { return }
        if peeks[id] != nil {
            if inside { peekTimers.removeValue(forKey: id)?.cancel() } else { scheduleRetract(id) }
            return
        }
        peekTimers.removeValue(forKey: id)?.cancel()
        guard inside else { return }
        peekTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.peek(id, keep: false)
        }
    }

    // MARK: Drag, dock and undock

    /// One step of a header or tab drag: at an outer display edge the note folds into its tab there, held at
    /// the pointer; anywhere else it's the note (a tab unfolds with its header under the pointer).
    private func dragMoved(_ panel: NotePanel, pointer: NSPoint, proposed: NSRect) -> NSRect {
        let id = panel.noteID
        if drags[id] == nil {
            drags[id] = Drag(fromTab: panel.frame.width <= DockLayout.maxTabWidth + 0.5)
            peekTimers.removeValue(forKey: id)?.cancel()
            peeks[id] = nil
        }
        if let hit = DockLayout.edge(at: pointer, in: Self.displays) {
            let tab = DockLayout.tabFrame(hit.edge, top: pointer.y + 16, size: tabSize(id), in: hit.display.visible)
            drags[id]?.target = (hit.edge, tab)
            controllers[id]?.tabEdge = hit.edge
            panel.setFrameless(true)
            return tab
        }
        drags[id]?.target = nil
        let collapsed = controllers[id]?.note.isCollapsed == true
        var size = noteSize(id)
        if collapsed { size.height = NoteLayout.collapsedHeight }
        panel.setFrameless(collapsed)
        if drags[id]?.fromTab != true && proposed.size == size { return proposed }
        return NSRect(x: pointer.x - 40, y: pointer.y + 16 - size.height, width: size.width, height: size.height)
    }

    private func dragEnded(_ panel: NotePanel) {
        let id = panel.noteID
        guard let drag = drags.removeValue(forKey: id) else { return snapToBottom(panel) }
        if let target = drag.target {
            dock(id, edge: target.edge, tab: target.tab)
        } else if dockEdges[id] != nil {
            undock(id)
        } else {
            scheduleFrameSave(panel)
            snapToBottom(panel)
        }
    }

    /// Docks a note with its tab at `tab`. The saved frame becomes where it peeks.
    private func dock(_ id: UUID, edge: DockEdge, tab: CGRect) {
        guard let panel = panels[id], let controller = controllers[id],
              let display = DockLayout.display(for: tab, in: Self.displays) else { return }
        if controller.note.isCollapsed, expandedHeights[id] == nil, let saved = savedFrames[id] {
            expandedHeights[id] = saved.height
        }
        let peek = DockLayout.peekFrame(edge, tab: tab, size: noteSize(id), in: display.visible)
        dockEdges[id] = edge
        controller.isDocked = true
        controller.tabEdge = edge
        controller.setDockEdge(edge)
        savedFrames[id] = peek
        Task { [appDatabase] in
            try? await appDatabase.updateNoteFrame(id: id, x: peek.minX, y: peek.minY, width: peek.width, height: peek.height)
        }
        panel.setFrameless(true)
        layoutTabs()
        reapplyBehavior(id)
        updateMouseMonitors()
    }

    /// Undocks a note where its window is now (a drag let it go there, or ⋯ › Undock put it there).
    private func undock(_ id: UUID) {
        guard let panel = panels[id], let controller = controllers[id] else { return }
        dockEdges[id] = nil
        tabFrames[id] = nil
        peeks[id] = nil
        peekTimers.removeValue(forKey: id)?.cancel()
        controller.isDocked = false
        controller.setDockEdge(nil)
        let collapsed = controller.note.isCollapsed
        panel.setFrameless(collapsed)
        reapplyBehavior(id)   // back to its pin; over a full-screen app it may leave for its desktop
        scheduleFrameSave(panel)
        if collapsed { snapToBottom(panel) }
        layoutTabs()
        updateMouseMonitors()
    }

    /// ⋯ › Dock to Edge (the nearer edge, at the note's height) or ⋯ › Undock (just off the edge, where it peeks).
    private func toggleDock(_ id: UUID) {
        guard let panel = panels[id], let controller = controllers[id] else { return }
        let displays = Self.displays
        if let edge = dockEdges[id] {
            guard let tab = tabFrames[id], let display = DockLayout.display(for: tab, in: displays) else { return }
            var frame = DockLayout.peekFrame(edge, tab: tab, size: noteSize(id), in: display.visible)
            frame.origin.x += edge == .left ? 40 : -40
            if controller.note.isCollapsed {
                frame = Self.rolledFrame(frame, toHeight: NoteLayout.collapsedHeight, screens: [display.visible])
            }
            peeks[id] = nil
            panel.setFrameless(controller.note.isCollapsed)
            panel.setFrame(frame, display: true)
            undock(id)
        } else {
            guard let display = DockLayout.display(for: panel.frame, in: displays) else { return }
            let edge = DockLayout.nearestEdge(of: panel.frame, on: display)
            controller.tabEdge = edge
            dock(id, edge: edge, tab: DockLayout.tabFrame(edge, top: panel.frame.maxY, size: tabSize(id), in: display.visible))
        }
    }

    // MARK: Pointing at an edge

    /// Tabs sit at normal level, so windows can cover them; pointing at their edge brings them in front. A
    /// covered tab never sees the pointer, so this watches mouse moves (no permission needed for those).
    private func updateMouseMonitors() {
        if dockEdges.isEmpty {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
            return
        }
        // Only with the app's event loop running: in tests, which have none, installing one stalled the main thread.
        guard mouseMonitors.isEmpty, NSApp.isRunning else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.edgePointerMoved(NSEvent.mouseLocation) }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.edgePointerMoved(NSEvent.mouseLocation) }
            return event
        }) { mouseMonitors.append(local) }
    }

    private func edgePointerMoved(_ pointer: NSPoint) {
        if let hit = DockLayout.edge(at: pointer, in: Self.displays, zone: DockLayout.edgeHover) {
            lowerTask?.cancel()
            lowerTask = nil
            if let hot = hotEdge, hot.edge == hit.edge, hot.display == hit.display { return }
            lowerTabs()
            hotEdge = hit
            for id in raisedTabs() {
                panels[id]?.level = .floating
                panels[id]?.orderFrontRegardless()
            }
        } else if hotEdge != nil, lowerTask == nil {
            lowerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.lowerTabs()
            }
        }
    }

    /// The tabs on the edge the pointer is at.
    private func raisedTabs() -> [UUID] {
        guard let hot = hotEdge else { return [] }
        return dockEdges.compactMap { id, edge in
            edge == hot.edge && tabFrames[id].map(hot.display.frame.intersects) == true ? id : nil
        }
    }

    private func isRaised(_ id: UUID) -> Bool { raisedTabs().contains(id) }

    /// Back behind whatever covered them (a pinned list's tab stays on top).
    private func lowerTabs() {
        lowerTask = nil
        let raised = raisedTabs()
        hotEdge = nil
        for id in raised where peeks[id] == nil && drags[id] == nil {
            reapplyBehavior(id)
            if panels[id]?.level == .normal { panels[id]?.orderBack(nil) }
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

// MARK: - Full-screen Spaces (private API)

/// Whether a display is showing an app's full-screen Space. AppKit has no API for it, so this asks the private
/// CoreGraphics calls window managers use (space type 4 is full screen), looked up at run time.
/// ponytail: private API. If a macOS drops a symbol this answers false, and a note unpinned over a full-screen
/// app stays there until full screen ends, as it did before.
@MainActor
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private static let fullScreenType: Int32 = 4
    private static let handle = dlopen(nil, RTLD_NOW)
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let currentSpace = symbol("CGSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
    private static let spaceType = symbol("CGSSpaceGetType", as: SpaceType.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }

    static func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let mainConnection, let currentSpace, let spaceType,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let display = CFUUIDCreateString(nil, uuid) else { return false }
        let connection = mainConnection()
        return spaceType(connection, currentSpace(connection, display)) == fullScreenType
    }
}
