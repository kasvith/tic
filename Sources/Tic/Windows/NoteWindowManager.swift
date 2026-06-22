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

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        super.init()
    }

    // MARK: - Opening notes

    /// Opens a floating panel for every saved note (called at launch).
    func restoreAll() async {
        do {
            let notes = try await appDatabase.allNotes()
            for note in notes { openNote(note) }
            NSLog("[Tic] restored \(notes.count) note panel(s)")
        } catch {
            NSLog("[Tic] restoreAll failed: \(error)")
        }
    }

    /// Shows the panel for a note, creating it if necessary.
    @discardableResult
    func openNote(_ note: Note) -> NotePanel {
        if let existing = panels[note.id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = NoteController(note: note, database: appDatabase)
        controllers[note.id] = controller
        controller.start()

        let panel = NotePanel(note: note, content: AnyView(NoteView(controller: controller)))
        panel.delegate = self
        panels[note.id] = panel

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak panel] floatOnTop, showOnAllSpaces in
            panel?.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
        }
        controller.onClose = { [weak panel] in
            panel?.close()   // triggers windowWillClose → teardown; does NOT delete the note
        }
        controller.onSetCollapsed = { [weak self, weak panel] collapsed in
            guard let self, let panel else { return }
            self.setCollapsed(panel, collapsed: collapsed, animate: true)
        }

        ensureOnScreen(panel)
        panel.orderFront(nil)

        // A note saved in the rolled-up state opens rolled up (keeping its expanded height).
        if note.isCollapsed {
            setCollapsed(panel, collapsed: true, animate: false)
        }
        return panel
    }

    /// Creates a fresh note (cascaded so it doesn't sit exactly on top of the last) and opens it.
    func newNote() async {
        let step = Double(panels.count % 8) * 28
        let note = Note(
            color: NoteColor.allCases.randomElement() ?? .yellow,
            frameX: 180 + step,
            frameY: 320 - step,
            sortIndex: panels.count
        )
        do {
            try await appDatabase.insert(note)
            openNote(note)
        } catch {
            NSLog("[Tic] newNote failed: \(error)")
        }
    }

    /// Brings every open note to the front (menu-bar "Show All").
    func showAll() {
        for panel in panels.values { panel.orderFront(nil) }
    }

    /// Rolls a panel up to just its title bar (or back to its expanded height), keeping the top
    /// edge fixed. While collapsed the height is locked so it can't be resized into a sliver.
    private func setCollapsed(_ panel: NotePanel, collapsed: Bool, animate: Bool) {
        let id = panel.noteID
        let current = panel.frame
        let collapsedHeight = NoteLayout.collapsedHeight

        let targetHeight: CGFloat
        if collapsed {
            if current.height > collapsedHeight { expandedHeights[id] = current.height }
            targetHeight = collapsedHeight
            panel.minSize = NSSize(width: panel.minSize.width, height: collapsedHeight)
            panel.maxSize = NSSize(width: .greatestFiniteMagnitude, height: collapsedHeight)
        } else {
            targetHeight = expandedHeights[id] ?? max(current.height, 240)
            expandedHeights[id] = nil
            panel.minSize = NSSize(width: panel.minSize.width, height: 160)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        let top = current.origin.y + current.height
        let newFrame = NSRect(
            x: current.origin.x, y: top - targetHeight,
            width: current.width, height: targetHeight
        )
        panel.setFrame(newFrame, display: true, animate: animate)
    }

    /// If a restored frame leaves the note essentially off-screen (e.g. a display was
    /// disconnected since it was last saved), recenter it on the main screen so it's never lost.
    private func ensureOnScreen(_ panel: NotePanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let overlap = visible.intersection(panel.frame)
        if overlap.width < 80 || overlap.height < 80 {
            let origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            )
            panel.setFrameOrigin(origin)
        }
    }

    var openCount: Int { panels.count }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification) }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        pendingFrameSaves[panel.noteID]?.cancel()
        pendingFrameSaves[panel.noteID] = nil
        expandedHeights[panel.noteID] = nil
        controllers[panel.noteID]?.stop()
        controllers[panel.noteID] = nil
        panels[panel.noteID] = nil
    }

    /// Debounced frame persistence — drag/resize fire continuously, so we save only after the
    /// gesture settles (300ms idle).
    private func scheduleFrameSave(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        let id = panel.noteID
        let live = panel.frame

        // While rolled up, the window is at its collapsed height. Still persist position/width,
        // but keep the EXPANDED height in the DB and reconstruct the expanded top (collapse keeps
        // the top edge fixed) — otherwise a move/resize done while collapsed is lost on relaunch.
        let collapsed = controllers[id]?.note.isCollapsed == true
        let height = collapsed ? (expandedHeights[id] ?? live.height) : live.height
        let x = live.origin.x
        let y = collapsed ? (live.maxY - height) : live.origin.y
        let width = live.width

        pendingFrameSaves[id]?.cancel()
        pendingFrameSaves[id] = Task { [appDatabase] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            try? await appDatabase.updateNoteFrame(id: id, x: x, y: y, width: width, height: height)
        }
    }
}
