import AppKit

/// App lifecycle owner. As a plain SwiftPM executable (no .app bundle yet) we must explicitly
/// adopt a regular activation policy so Tic gets a Dock icon and can take foreground focus.
/// All real state lives in `AppModel.shared`; this just sequences launch and the Dock menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var newNoteKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await AppModel.shared.bootstrap() }
        installNewNoteShortcut()
    }

    /// ⌘N → New Note while Tic is the active app. A menu-style `MenuBarExtra` button's
    /// `keyboardShortcut` only fires while that menu is open, so we dispatch it ourselves via a
    /// local key monitor (fires whenever any Tic window is key).
    private func installNewNoteShortcut() {
        newNoteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Membership test (not == .command) so Caps Lock / Fn in the flags don't break it,
            // and case-insensitive so "N" under Caps Lock still matches.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "n" else { return event }
            Task { @MainActor in AppModel.shared.newNote() }
            return nil   // consume
        }
    }

    /// Right-click the Dock icon → New List.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New List", action: #selector(newListFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newListFromDock() {
        AppModel.shared.newNote()
    }
}
