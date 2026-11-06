import AppKit
import GRDB
import Observation
import SystemConfiguration

/// Sync between Macs through a folder that something else keeps in sync — iCloud Drive by default,
/// or any Dropbox / Google Drive / OneDrive / Syncthing folder. Tic only reads and writes plain files
/// there, so no iCloud entitlement, account or server is involved.
///
/// Each Mac writes `devices/<its id>.json` (a `SyncSnapshot`) and reads everyone else's. A cycle runs
/// at start, a couple of seconds after a synced edit, every 30 s, and on wake; it records local edits,
/// merges the other files and writes the result (`AppDatabase.syncCycle`). Open panels update
/// through the existing observations. Off by default.
@MainActor
@Observable
final class FolderSync {
    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        /// When that Mac last wrote a change (nil if it never has).
        let latestChange: Date?
    }

    private(set) var isEnabled: Bool
    private(set) var folder: URL?
    /// The other Macs whose files are in the folder.
    private(set) var peers: [Peer] = []
    /// Why sync isn't working right now, in words for the Settings window; nil when all is well.
    private(set) var problem: String?
    private(set) var lastSynced: Date?

    var deviceName: String { name }
    /// This Mac's id: issued once, persisted in defaults, and the name of its file in the folder.
    var deviceID: String { snapshot.device }

    /// Closes the panels of lists another Mac deleted (set by `AppModel`, keeping this AppKit-light).
    @ObservationIgnored var onNotesDeleted: ([UUID]) -> Void = { _ in }

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let name: String
    @ObservationIgnored private let clock: @MainActor () -> Int64
    @ObservationIgnored private var snapshot: SyncSnapshot
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var observers: [Any] = []

    private static let enabledKey = "syncEnabled"
    private static let deviceKey = "syncDeviceID"
    private static let folderKey = "syncFolderPath"
    static let pollInterval: Duration = .seconds(30)

    /// `stateURL` keeps this Mac's own snapshot (device id, stamps) outside the sync folder, so
    /// switching folders or losing the folder for a while forgets nothing. `clock` (ms since 1970) is
    /// injectable so tests can simulate a Mac whose clock runs behind.
    init(database: AppDatabase, stateURL: URL, defaults: UserDefaults = .standard,
         name: String = FolderSync.computerName(),
         clock: @escaping @MainActor () -> Int64 = { Date().syncMillis }) {
        self.database = database
        self.stateURL = stateURL
        self.defaults = defaults
        self.name = name
        self.clock = clock
        // This Mac's id is issued once and kept in its own default, apart from the state file: if
        // that file is ever lost, the Mac keeps its identity and overwrites its own file in the folder
        // instead of leaving a ghost "Mac" behind.
        let loaded = try? JSONDecoder().decode(SyncSnapshot.self, from: Data(contentsOf: stateURL))
        let device = defaults.string(forKey: Self.deviceKey) ?? loaded?.device ?? UUID().uuidString
        defaults.set(device, forKey: Self.deviceKey)
        var start = loaded ?? SyncSnapshot(device: device, name: name)
        start.device = device
        snapshot = start
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder()
    }

    // MARK: - Settings

    /// Called once at launch: resumes syncing if it was on.
    func start() {
        if isEnabled { begin() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && folder == nil && !chooseFolder() { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { begin() } else { end() }
    }

    /// The standard folder picker. Returns false if the user cancelled.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder that each of your Macs syncs, such as one in iCloud Drive or Dropbox."
        panel.directoryURL = folder ?? Self.iCloudDrive()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        setFolder(url)
        return true
    }

    func setFolder(_ url: URL) {
        folder = url
        defaults.set(url.path, forKey: Self.folderKey)
        peers = []
        problem = nil
        if isEnabled { syncNow() }
    }

    /// "iCloud Drive › Tic" — the folder and its parent, as Finder names them.
    var folderDisplayName: String? {
        folder.map {
            let fm = FileManager.default
            return "\(fm.displayName(atPath: $0.deletingLastPathComponent().path)) › \(fm.displayName(atPath: $0.path))"
        }
    }

    // MARK: - Running

    private func begin() {
        observation = database.observeSyncedChanges { [weak self] in
            Task { @MainActor in self?.syncSoon() }
        }
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.syncNow()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncNow() }
            },
            // The lid closing is the moment edits most need to reach the folder: write them now
            // instead of waiting out the debounce.
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.debounce != nil { self?.syncNow() } }
            },
        ]
        syncNow()
    }

    private func end() {
        observation = nil
        poller?.cancel()
        debounce?.cancel()
        debounce = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        peers = []
        problem = nil
    }

    /// A synced edit just landed: write it out shortly, once a burst of typing has settled.
    private func syncSoon() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        Task { await sync() }
    }

    /// One cycle; overlapping requests fold into a single re-run.
    func sync() async {
        guard isEnabled, let folder else { return }
        if running { rerun = true; return }
        running = true
        debounce?.cancel()
        debounce = nil
        await cycle(in: folder)
        running = false
        if rerun {
            rerun = false
            await sync()
        }
    }

    private func cycle(in folder: URL) async {
        let me = snapshot.device
        let read: FolderRead
        do {
            read = try await Task.detached { try Self.read(folder, excluding: me) }.value
        } catch {
            problem = "Can't reach this folder. Check that it still exists and that its sync app is running, "
                + "or choose another folder."
            return
        }

        let newer = read.others.filter { $0.schema > SyncSnapshot.schemaVersion }
        let usable = read.others.filter { $0.schema <= SyncSnapshot.schemaVersion }
        let now = clock()
        do {
            let result = try await database.syncCycle(mine: snapshot, others: usable, now: now)
            var next = result.snapshot
            next.name = name
            next.schema = SyncSnapshot.schemaVersion
            let changed = !next.sameContent(as: snapshot) || next.name != snapshot.name
            if changed { next.writtenAt = now }
            if changed || !read.hasMine {
                let file = Self.file(for: me, in: folder), state = stateURL, toWrite = next
                try await Task.detached { try Self.write(toWrite, to: [file, state]) }.value
            }
            snapshot = next
            if !result.changes.deletedNotes.isEmpty {
                onNotesDeleted(result.changes.deletedNotes.compactMap(UUID.init(uuidString:)))
            }
            peers = read.others
                .map { peer in
                    Peer(id: peer.device, name: peer.name,
                         latestChange: peer.writtenAt > 0 ? Date(syncMillis: peer.writtenAt) : nil)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastSynced = Date()
            problem = newer.isEmpty ? nil
                : "\(newer.map(\.name).joined(separator: ", ")) runs a newer Tic. "
                    + "Update Tic on this Mac to keep syncing with it."
        } catch {
            NSLog("[Tic] sync failed: \(error)")
            problem = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Files (off the main actor: an iCloud file may download as it's read)

    private struct FolderRead: Sendable {
        var others: [SyncSnapshot]
        var hasMine: Bool
    }

    private nonisolated static func file(for device: String, in folder: URL) -> URL {
        folder.appendingPathComponent("devices", isDirectory: true).appendingPathComponent("\(device).json")
    }

    /// The other Macs' snapshots. A missing folder is created only when its parent exists, so an
    /// unmounted Dropbox reads as "can't reach" rather than quietly syncing to a local folder. An
    /// unreadable file (mid-download, say) is skipped and read on the next cycle.
    private nonisolated static func read(_ folder: URL, excluding me: String) throws -> FolderRead {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard fm.fileExists(atPath: folder.deletingLastPathComponent().path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } else if !isDir.boolValue {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        try fm.createDirectory(at: devices, withIntermediateDirectories: true)
        var others: [SyncSnapshot] = []
        var hasMine = false
        for url in try fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
            if url.deletingPathExtension().lastPathComponent == me { hasMine = true; continue }
            if let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(SyncSnapshot.self, from: data),
               snap.device != me {
                others.append(snap)
            }
        }
        return FolderRead(others: others, hasMine: hasMine)
    }

    private nonisolated static func write(_ snapshot: SyncSnapshot, to urls: [URL]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        for url in urls { try data.write(to: url, options: .atomic) }
    }

    // MARK: - Defaults

    nonisolated static func iCloudDrive() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `iCloud Drive/Tic` when iCloud Drive is on; otherwise none, and turning sync on asks.
    nonisolated static func defaultFolder() -> URL? {
        iCloudDrive()?.appendingPathComponent("Tic", isDirectory: true)
    }

    /// The Mac's name from Sharing settings ("Kasun's MacBook Pro").
    nonisolated static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
    }
}
