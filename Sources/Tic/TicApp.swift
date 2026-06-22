import SwiftUI

@main
struct TicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Tic", systemImage: "checklist") {
            Button("New Note") {
                // TODO: spawn a new sticky note panel
            }
            Divider()
            Button("Quit Tic") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
