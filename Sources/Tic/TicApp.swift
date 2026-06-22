import SwiftUI
import AppKit

@main
struct TicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Native .menu style (default): its content is rebuilt each time the menu opens, so it
        // reliably reflects the current lists — unlike .window, which didn't re-render here.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

/// The status-bar icon: a template-rendered menu-bar glyph (bundled via SPM resources), falling
/// back to an SF Symbol if the resource can't be found.
private struct MenuBarLabel: View {
    var body: some View {
        if let icon = Self.icon {
            Image(nsImage: icon).renderingMode(.template)
        } else {
            Image(systemName: "checklist")
        }
    }

    private static let icon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
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

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Quit Tic") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }
}
