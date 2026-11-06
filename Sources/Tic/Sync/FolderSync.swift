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
    /// A cycle is running (Sync Now shows its mark meanwhile).
    private(set) var isSyncing = false
    /// Per list, bumped each time a cycle sends or brings changes for it — what flashes a list's sync
    /// mark. Only lists that sync ever appear here.
    private(set) var activity: [UUID: Int] = [:]

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
        if isSyncing { rerun = true; return }
        isSyncing = true
        debounce?.cancel()
        debounce = nil
        await cycle(in: folder)
        isSyncing = false
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
            let images = try await fetchImages(for: usable, available: read.imageFiles, in: folder)
            let result = try await database.syncCycle(mine: snapshot, others: usable, images: images, now: now)
            var next = result.snapshot
            next.name = name
            next.schema = SyncSnapshot.schemaVersion
            let publishedChanged = !next.published().sameContent(as: snapshot.published()) || next.name != snapshot.name
            if publishedChanged { next.writtenAt = now }
            let published = next.published()
            let recordChanged = publishedChanged || !next.sameContent(as: snapshot) || next.clock != snapshot.clock

            let file = Self.file(for: me, in: folder), state = stateURL, full = next
            let writeFolder = publishedChanged || !read.hasMine
            if recordChanged || writeFolder {
                try await Task.detached {
                    if recordChanged { try Self.write(full, to: state) }
                    if writeFolder { try Self.write(published, to: file) }
                }.value
            }
            for id in Self.touchedLists(from: snapshot.published(), to: published).compactMap(UUID.init(uuidString:)) {
                activity[id, default: 0] += 1
            }
            snapshot = next
            try await publishImages(of: published, existing: read.imageFiles, in: folder)
            let referenced = Set(([published] + read.others)
                .flatMap { $0.tasks.values.compactMap { $0.image.value?.hash } })
            let imagesDir = Self.imagesFolder(folder)
            await Task.detached { Self.removeUnusedImages(in: imagesDir, keeping: referenced) }.value

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

    /// The lists whose published content changed between two cycles — a change sent from here or
    /// taken from another Mac, either way.
    nonisolated static func touchedLists(from old: SyncSnapshot, to new: SyncSnapshot) -> Set<String> {
        var out = Set<String>()
        for id in Set(old.notes.keys).union(new.notes.keys) where old.notes[id] != new.notes[id] { out.insert(id) }
        for id in Set(old.tasks.keys).union(new.tasks.keys) where old.tasks[id] != new.tasks[id] {
            if let note = new.tasks[id]?.noteId ?? old.tasks[id]?.noteId { out.insert(note) }
        }
        return out.filter { new.notes[$0] != nil }
    }

    // MARK: - Images

    /// The bytes of pictures another Mac added that this Mac lacks and is likely to take (its register
    /// would win), read from `images/`. A file whose hash doesn't match — still downloading — is left out.
    private func fetchImages(for others: [SyncSnapshot], available: Set<String>, in folder: URL) async throws
        -> [String: Data] {
        let local = try await database.syncImageHashes()
        var wanted = Set<String>()
        for other in others {
            for (id, task) in other.tasks {
                guard let image = task.image.value, !local.contains(image.hash), available.contains(image.hash)
                else { continue }
                if let ours = snapshot.tasks[id]?.image, SyncMerge.pick(ours, task.image) != task.image { continue }
                wanted.insert(image.hash)
            }
        }
        guard !wanted.isEmpty else { return [:] }
        let dir = Self.imagesFolder(folder)
        return await Task.detached { Self.loadImages(wanted, from: dir) }.value
    }

    /// Writes any picture this Mac publishes that isn't in the folder yet. Each file is named by its
    /// content hash and never changes, so two Macs writing the same picture write the same bytes.
    private func publishImages(of published: SyncSnapshot, existing: Set<String>, in folder: URL) async throws {
        let missing = Set(published.tasks.values.compactMap { $0.image.value?.hash }).subtracting(existing)
        for hash in missing {
            guard let data = try await database.syncImageData(hash: hash) else { continue }
            let url = Self.imagesFolder(folder).appendingPathComponent("\(hash).png")
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
        }
    }

}

// MARK: - Files (off the main actor: an iCloud file may download as it's read)

extension FolderSync {
    fileprivate struct FolderRead: Sendable {
        var others: [SyncSnapshot]
        var hasMine: Bool
        /// Hashes of the picture files in `images/`.
        var imageFiles: Set<String>
    }

    fileprivate nonisolated static func file(for device: String, in folder: URL) -> URL {
        folder.appendingPathComponent("devices", isDirectory: true).appendingPathComponent("\(device).json")
    }

    fileprivate nonisolated static func imagesFolder(_ folder: URL) -> URL {
        folder.appendingPathComponent("images", isDirectory: true)
    }

    /// The other Macs' snapshots. A missing folder is created only when its parent exists, so an
    /// unmounted Dropbox reads as "can't reach" rather than quietly syncing to a local folder. An
    /// unreadable file (mid-download, say) is skipped and read on the next cycle.
    fileprivate nonisolated static func read(_ folder: URL, excluding me: String) throws -> FolderRead {
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
        try fm.createDirectory(at: imagesFolder(folder), withIntermediateDirectories: true)
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
        let images = Set(try fm.contentsOfDirectory(atPath: imagesFolder(folder).path)
            .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
        return FolderRead(others: others, hasMine: hasMine, imageFiles: images)
    }

    fileprivate nonisolated static func write(_ snapshot: SyncSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    fileprivate nonisolated static func loadImages(_ hashes: Set<String>, from dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for hash in hashes {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(hash).png")),
                  AppDatabase.imageHash(data) == hash else { continue }
            out[hash] = data
        }
        return out
    }

    /// Deletes picture files that no Mac's file refers to any more — but only a week after they were
    /// last written, so a Mac whose newer file hasn't arrived yet can't lose a picture it still uses.
    nonisolated static func removeUnusedImages(in dir: URL, keeping referenced: Set<String>,
                                               olderThan age: TimeInterval = 7 * 24 * 60 * 60) {
        let fm = FileManager.default
        let dateKey = URLResourceKey.contentModificationDateKey
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [dateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in files where url.pathExtension == "png" {
            let hash = url.deletingPathExtension().lastPathComponent
            guard !referenced.contains(hash),
                  let modified = try? url.resourceValues(forKeys: [dateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
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
