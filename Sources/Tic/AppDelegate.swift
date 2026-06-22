import AppKit

/// App lifecycle owner. As a plain SwiftPM executable (no .app bundle yet) we must explicitly
/// adopt a regular activation policy so Tic gets a Dock icon and can take foreground focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appDatabase: AppDatabase?
    private(set) var windowManager: NoteWindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        do {
            let db = try AppDatabase.makeShared()
            appDatabase = db
            NSLog("[Tic] Database ready at \(db.path)")

            let manager = NoteWindowManager(appDatabase: db)
            windowManager = manager
            Task { await manager.restoreAll() }
        } catch {
            NSLog("[Tic] Failed to open database: \(error)")
        }
    }
}
