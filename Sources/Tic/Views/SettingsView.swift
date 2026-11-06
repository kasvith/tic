import AppKit
import SwiftUI

/// Tic's Settings window (⌘, · Tic › Settings… · the menu-bar menu): a standard macOS `Settings`
/// scene with three grouped-form tabs. Everything here is a thin view over `AppModel` — the launch
/// item, `UpdateChecker`, `FolderSync` and the MCP service own the actual behaviour.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            AgentsSettings().tabItem { Label("AI Agents", systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

/// "today at 17:42", "yesterday at 09:10", "3 Nov at 17:42".
private func settingsWhen(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "today at \(time)" }
    if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
    return "\(date.formatted(.dateTime.day().month(.abbreviated))) at \(time)"
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var model = AppModel.shared
    private var updates: UpdateChecker { model.updates }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at Login")
                    Text("Open Tic and its notes when you log in.")
                }
            }
            Section("About") {
                LabeledContent("Version", value: updates.currentVersion ?? "Development build")
                Picker("Check for updates", selection: Binding(
                    get: { updates.frequency }, set: { updates.setFrequency($0) }
                )) {
                    ForEach(UpdateChecker.Frequency.allCases) { Text($0.title).tag($0) }
                }
                .disabled(updates.currentVersion == nil)
                LabeledContent {
                    if updates.available != nil {
                        Button("View Update…") { model.openUpdate() }
                    } else {
                        Button("Check Now") { Task { await updates.check() } }
                            .disabled(updates.currentVersion == nil || updates.isChecking)
                    }
                } label: {
                    Text(updateStatus).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 270)
    }

    private var updateStatus: String {
        guard updates.currentVersion != nil else { return "Update checks need the packaged app" }
        if updates.isChecking { return "Checking…" }
        if let available = updates.available { return "Version \(available.version) is available" }
        guard let last = updates.lastChecked else { return "Not checked yet" }
        return "Up to date · last checked \(settingsWhen(last))"
    }
}

// MARK: - Sync

private struct SyncSettings: View {
    @State private var model = AppModel.shared
    private var sync: FolderSync { model.sync }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                    Text("Sync lists between Macs")
                    Text("The same lists on each Mac. Which lists are open, and where they sit, stay on each Mac.")
                }
            }
            Section {
                HStack {
                    Label {
                        Text(sync.folderDisplayName ?? "No folder chosen")
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                    }
                    Spacer()
                    Button("Choose…") { sync.chooseFolder() }
                }
                .disabled(!sync.isEnabled)
                if sync.isEnabled, let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Sync folder")
            } footer: {
                Text("Choose the same folder on each Mac. iCloud Drive, Dropbox, Google Drive, OneDrive "
                     + "and Syncthing folders all work.")
                    .foregroundStyle(.secondary)
            }
            if sync.isEnabled {
                Section {
                    LabeledContent {
                        Text(thisMacStatus)
                    } label: {
                        HStack(spacing: 6) {
                            Text(sync.deviceName)
                            Text("This Mac")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        }
                    }
                    if sync.peers.isEmpty {
                        Text("No other Macs yet").foregroundStyle(.secondary)
                    }
                    ForEach(sync.peers) { peer in
                        LabeledContent(peer.name, value: peer.latestChange
                            .map { "Latest changes \(settingsWhen($0))" } ?? "No changes yet")
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text(sync.peers.isEmpty
                         ? "Turn on sync on your other Mac and choose this same folder."
                         : "Lists created on another Mac arrive closed. Open them from Recent Lists or Search Lists.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    private var thisMacStatus: String {
        if sync.problem != nil { return "Needs attention" }
        return sync.lastSynced == nil ? "Starting…" : "Up to date"
    }
}

// MARK: - AI Agents (MCP)

/// The MCP switch with live status, then one client's copy-paste (or one-click) setup. Every
/// snippet spawns the same `Tic --mcp`, so this is one command presented per client.
private struct AgentsSettings: View {
    @State private var model = AppModel.shared
    @State private var selection: String
    @State private var copied = false

    private let clients: [MCPClient]
    private let inApplications: Bool

    init() {
        let exe = Bundle.main.executableURL?.path ?? "Tic"
        clients = MCPClients.all(executablePath: exe)
        inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications")
        _selection = State(initialValue: "Claude Code")
    }

    private var client: MCPClient { clients.first { $0.id == selection } ?? clients[0] }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.mcpEnabled }, set: { model.setMCPEnabled($0) })) {
                    Text("Allow AI agents to use Tic")
                    Text("Lets Claude, Cursor and other MCP clients draft and tick your lists.")
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.mcpEnabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
            }
            Section {
                Picker("Client", selection: $selection) {
                    ForEach(clients, id: \.id) { Text($0.name).tag($0.id) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(client.detail).foregroundStyle(.secondary)
                    ScrollView {
                        Text(client.snippet)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 130)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    HStack(spacing: 8) {
                        if let link = client.deeplink {
                            Button("Add to \(client.name)") { open(link) }.buttonStyle(.borderedProminent)
                        }
                        Button(copied ? "Copied" : "Copy") { copy() }
                        if let path = client.configPath {
                            Button("Open Config File") { openConfig(path) }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Connect a client")
            } footer: {
                if !inApplications {
                    Text("Tic isn't in /Applications. The path in this command changes if you move the app.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onChange(of: selection) { copied = false }
    }

    private var statusText: String {
        guard model.mcpEnabled else { return "Off" }
        let n = model.mcpConnections
        return n == 0 ? "Running · no agents connected" : "Running · \(n) connected"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.snippet, forType: .string)
        copied = true
    }

    /// Opens a client install deeplink (Cursor / VS Code).
    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Opens the client's config file, or reveals its folder in Finder if the file doesn't exist yet.
    private func openConfig(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
