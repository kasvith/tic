import SwiftUI

@main
struct TicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Native .menu style (default): its content is rebuilt each time the menu opens, so it
        // reliably reflects the current lists — unlike .window, which didn't re-render here.
        MenuBarExtra("Tic", systemImage: "checklist") {
            MenuBarContent()
        }
    }
}

/// The Tic menu bar menu: New List, recent lists (with a "More Lists" submenu for up to 100),
/// a Search window, and Quit.
private struct MenuBarContent: View {
    private var model: AppModel { AppModel.shared }
    private static let recentCount = 5
    private static let moreCount = 95   // 5 + 95 = up to 100 reachable from the menu

    var body: some View {
        Button("New List") { model.newNote() }
            .keyboardShortcut("n")   // hint + works while the menu is open; AppDelegate covers the rest

        Divider()

        let recent = model.notes.sorted { $0.updatedAt > $1.updatedAt }
        if recent.isEmpty {
            Text("No lists yet")
        } else {
            Section("Recent Lists") {
                ForEach(Array(recent.prefix(Self.recentCount))) { note in
                    Button(label(note)) { model.open(note) }
                }
            }
            let more = Array(recent.dropFirst(Self.recentCount).prefix(Self.moreCount))
            if !more.isEmpty {
                Menu("More Lists") {
                    ForEach(more) { note in
                        Button(label(note)) { model.open(note) }
                    }
                }
            }
        }

        Divider()

        Button("Search Lists…") { model.openSearch() }
        Button("Quit Tic") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }
}
