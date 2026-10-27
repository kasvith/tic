import SwiftUI
import AppKit

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
/// back to an SF Symbol if the resource can't be found. A small dot marks an update the user
/// hasn't looked at yet (`UpdateChecker.isUnseen`). The dot is drawn *into* the image: the status
/// item renders only the label's image, so a SwiftUI overlay never shows.
private struct MenuBarLabel: View {
    private var updates: UpdateChecker { AppModel.shared.updates }

    var body: some View {
        if let icon = updates.isUnseen ? Self.badgedIcon : Self.icon {
            Image(nsImage: icon).renderingMode(.template)
        } else {
            Image(systemName: updates.isUnseen ? "checklist.checked" : "checklist")
        }
    }

    private static let glyph: NSImage? = {
        guard let url = menuBarIconURL() else { return nil }
        return NSImage(contentsOf: url)
    }()
    private static let icon = glyph.map { compose($0, dot: false) }
    private static let badgedIcon = glyph.map { compose($0, dot: true) }

    /// 20×18 template image: the 18pt glyph plus (optionally) a 6pt dot at the top-right, with a
    /// knocked-out ring so it reads as a badge. Both variants share a size so nothing shifts.
    private static func compose(_ glyph: NSImage, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            if dot {
                let dot = NSRect(x: 14, y: 11, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func menuBarIconURL() -> URL? {
        let fileManager = FileManager.default
        let fileName = "MenuBarIcon.png"
        let resourceBundleName = "Tic_Tic.bundle"
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()

        var candidates: [URL] = []

        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png") {
            candidates.append(url)
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(fileName))
        }

        for baseURL in [Bundle.main.bundleURL, Bundle.main.resourceURL, executableDirectory].compactMap({ $0 }) {
            candidates.append(baseURL.appendingPathComponent(resourceBundleName).appendingPathComponent(fileName))
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
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

        Button("AI Agents (MCP)…") { model.openMCPSetup() }

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        if let title = model.updates.menuTitle {
            Divider()
            Button(title) { model.openUpdate() }
                .disabled(model.updates.installState == .installing)
        }

        Divider()

        Button("Quit Tic") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }
}
