import AppKit
import Foundation
import Observation
import UserNotifications

/// Checks GitHub Releases for a newer Tic and surfaces it quietly: a menu-bar item while an update
/// exists, a dot on the menu-bar icon until the user has looked, and one notification banner per
/// new version. Either opens the update window (`UpdateView`): the notes for every version since this
/// one, then Update Now, which installs it (`UpdateInstaller`) and restarts Tic.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Sendable, Equatable {
        let version: String   // "0.6.0" (tag without the leading "v")
        let url: URL          // the GitHub release page
        /// Notes for recent published releases, newest first; `notes(since:)` picks the ones to show.
        var notes: [ReleaseNotes] = []

        /// What's new since `current`: the notes of every newer version, newest first.
        func notes(since current: String) -> [ReleaseNotes] {
            notes.filter { UpdateChecker.isNewer($0.version, than: current) }
        }
    }

    enum InstallState: Equatable {
        case idle
        case installing
        case failed(String)
    }

    /// A release newer than the running build, if the last check found one.
    private(set) var available: Release?

    /// True while `available` hasn't been looked at yet — drives the dot on the menu-bar icon.
    /// Cleared (and remembered per version) once the menu is opened with the item in it, or the
    /// item is clicked.
    private(set) var isUnseen = false

    /// Where an Update Now is at; drives the update window's footer and the menu item.
    private(set) var installState = InstallState.idle

    /// The menu item's title; also how the menu-tracking observer recognises our menu.
    var menuTitle: String? {
        available.map {
            installState == .installing ? "Installing v\($0.version)…" : "Update Available: v\($0.version)…"
        }
    }

    /// The running build's `CFBundleShortVersionString`. Nil under `swift run` (no bundle), which
    /// disables the checker entirely.
    let currentVersion: String?

    /// The list, not `releases/latest`: one request brings the notes for every version since this one.
    private nonisolated static let releasesURL =
        URL(string: "https://api.github.com/repos/kasvith/tic/releases?per_page=20")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let notifiedVersionKey = "updateNotifiedVersion"
    private static let seenVersionKey = "updateSeenVersion"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async throws -> Release
    @ObservationIgnored private let notify: @MainActor (Release, String) async -> Void
    @ObservationIgnored private let installer: @Sendable (Release) async throws -> Void
    @ObservationIgnored private let restart: @MainActor () -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// The parameters exist for tests; the app uses the defaults (GitHub + a real banner).
    init(
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        defaults: UserDefaults = .standard,
        fetch: @escaping @Sendable () async throws -> Release = UpdateChecker.fetchLatest,
        notify: @escaping @MainActor (Release, String) async -> Void = UpdateChecker.postBanner,
        installer: @escaping @Sendable (Release) async throws -> Void = UpdateChecker.installOverRunningApp,
        restart: @escaping @MainActor () -> Void = UpdateChecker.relaunch
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.notify = notify
        self.installer = installer
        self.restart = restart

        // Opening the menu (and so seeing the item) counts as "seen": the dot goes once it closes.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let menu = note.object as? NSMenu   // queue: .main, so this is main-actor safe
            MainActor.assumeIsolated {
                guard let self, let menu, let title = self.menuTitle,
                      menu.items.contains(where: { $0.title == title }) else { return }
                self.markSeen()
            }
        }
    }

    /// Check shortly after launch (so it never competes with restoring notes), then daily.
    func start() {
        guard currentVersion != nil else {
            NSLog("[Tic] update check disabled: no bundle version (swift run?)")
            return
        }
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func check() async {
        guard let currentVersion else { return }
        do {
            let release = try await fetch()
            guard Self.isNewer(release.version, than: currentVersion) else {
                available = nil
                isUnseen = false
                return
            }
            available = release
            isUnseen = defaults.string(forKey: Self.seenVersionKey) != release.version
            NSLog("[Tic] update available: v\(release.version)")
            await notifyOnce(release)
        } catch {
            NSLog("[Tic] update check failed: \(error)")   // silent for the user, by design
        }
    }

    func openReleasePage() {
        guard let available else { return }
        markSeen()
        NSWorkspace.shared.open(available.url)
    }

    /// Update Now: installs `available` over this copy, then restarts into it. A failure is shown in the
    /// update window (with the release page as the way out); the installed copy is left untouched.
    func install() {
        guard let release = available, installState != .installing else { return }
        markSeen()
        installState = .installing
        Task {
            do {
                try await installer(release)
                restart()
            } catch {
                NSLog("[Tic] update install failed: \(error)")
                installState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Forgets a failed attempt when the update window closes, so it opens fresh next time.
    func clearFailure() {
        if case .failed = installState { installState = .idle }
    }

    nonisolated static func installOverRunningApp(_ release: Release) async throws {
        try await UpdateInstaller().install(version: release.version, replacing: Bundle.main.bundleURL)
    }

    static func relaunch() {
        UpdateInstaller.relaunchAfterExit(Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    func markSeen() {
        guard let available else { return }
        isUnseen = false
        defaults.set(available.version, forKey: Self.seenVersionKey)
    }

    /// One banner per version, remembered in `defaults` so daily checks and relaunches never repeat it.
    private func notifyOnce(_ release: Release) async {
        guard let currentVersion, defaults.string(forKey: Self.notifiedVersionKey) != release.version else { return }
        defaults.set(release.version, forKey: Self.notifiedVersionKey)
        await notify(release, currentVersion)
    }

    // MARK: - Version compare

    /// Numeric, component-wise compare ("0.10.0" > "0.9.0"; "1.0" == "1.0.0"); a leading "v" is ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func components(_ version: String) -> [Int] {
        var s = Substring(version)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        return s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {   // snake_case keys: tag_name, html_url, published_at
        let tagName: String
        let htmlUrl: URL
        let body: String?
        let publishedAt: Date?
        let draft: Bool
        let prerelease: Bool

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    /// Decodes the releases list: the newest published (non-draft, non-pre-release) version, plus the
    /// notes of every published release, newest first. Tags lose their leading "v".
    nonisolated static func parse(_ data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let published = try decoder.decode([GitHubRelease].self, from: data)
            .filter { !$0.draft && !$0.prerelease }
            .sorted { isNewer($0.version, than: $1.version) }
        guard let latest = published.first else { throw URLError(.cannotParseResponse) }
        return Release(
            version: latest.version, url: latest.htmlUrl,
            notes: published.map { ReleaseNotes.parse(version: $0.version, date: $0.publishedAt, body: $0.body ?? "") }
        )
    }

    // MARK: - Banner

    /// Authorization is requested here, the first time an update is actually found, so the system
    /// prompt appears with the banner that explains it. Declined → the menu item still works and
    /// we never ask again for this version. `UNUserNotificationCenter` needs a bundle id (swift run).
    static func postBanner(_ release: Release, currentVersion: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert])
        } catch {
            NSLog("[Tic] notification authorization failed: \(error)")
            return
        }
        guard granted else {
            NSLog("[Tic] notifications declined; the menu item still shows the update")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Tic v\(release.version) is available"
        content.body = "You're on v\(currentVersion). Click to see what's new and download."
        let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            NSLog("[Tic] update notification failed: \(error)")
        }
    }
}

/// One release's notes, as git-cliff writes them: `### Features`-style headings over
/// `- *(scope)* Message` bullets. The scope is dropped; it means something to the code, not to users.
struct ReleaseNotes: Sendable, Equatable, Identifiable {
    struct Section: Sendable, Equatable {
        let title: String
        var items: [String]
    }

    let version: String
    let date: Date?
    let sections: [Section]

    var id: String { version }

    static func parse(version: String, date: Date?, body: String) -> ReleaseNotes {
        var sections: [Section] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                sections.append(Section(title: String(line.dropFirst(4)), items: []))
            } else if line.hasPrefix("- ") {
                var item = Substring(line.dropFirst(2))
                if item.hasPrefix("*("), let end = item.range(of: ")* ") { item = item[end.upperBound...] }
                if sections.isEmpty { sections.append(Section(title: "", items: [])) }
                sections[sections.count - 1].items.append(String(item))
            }
        }
        return ReleaseNotes(version: version, date: date, sections: sections)
    }
}
