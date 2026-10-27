import CryptoKit
import Foundation

/// Replaces the installed Tic with a release: downloads `Tic.zip`, checks it against
/// `Tic.zip.sha256`, unpacks it, confirms it's Tic at the expected version with an intact signature,
/// then swaps it in. Files Tic downloads itself get no quarantine flag (it isn't sandboxed and doesn't
/// set `LSFileQuarantineEnabled`), so the new copy opens without Gatekeeper's block, unsigned or not.
struct UpdateInstaller: Sendable {
    enum Failure: LocalizedError, Equatable {
        case notWritable(String)
        case checksumMismatch
        case badArchive
        case wrongApp
        case wrongVersion(String)
        case badSignature

        var errorDescription: String? {
            switch self {
            case .notWritable(let folder): "Tic can't replace itself in \(folder)."
            case .checksumMismatch: "The download didn't match its checksum."
            case .badArchive: "The download didn't contain Tic."
            case .wrongApp: "The download wasn't Tic."
            case .wrongVersion(let found): "The download was v\(found), not the expected version."
            case .badSignature: "The downloaded app's signature is broken."
            }
        }
    }

    /// Fetches a release asset. Injected by tests; the app downloads from GitHub.
    var download: @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Pinned to the version the user was offered, not `latest`, so a release landing mid-update can't
    /// swap in something they didn't see the notes for.
    static func assetURL(_ name: String, version: String) -> URL {
        URL(string: "https://github.com/kasvith/tic/releases/download/v\(version)/\(name)")!
    }

    /// Replaces the app at `app` with `version`. On any failure the installed copy is left as it was.
    func install(version: String, replacing app: URL) async throws {
        let files = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: app.path) else {
            throw Failure.notWritable(folder.path)
        }

        async let zip = download(Self.assetURL("Tic.zip", version: version))
        async let checksum = download(Self.assetURL("Tic.zip.sha256", version: version))
        let (archiveData, checksumData) = try await (zip, checksum)
        let expected = String(bytes: checksumData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first
        let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard expected?.lowercased() == actual else { throw Failure.checksumMismatch }

        // A scratch folder on the app's own volume, so the final moves are renames, not copies.
        let staging = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true
        )
        defer { try? files.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("Tic.zip")
        try archiveData.write(to: archive)
        guard await Self.run("/usr/bin/ditto", "-x", "-k", archive.path, staging.path) else { throw Failure.badArchive }

        let new = staging.appendingPathComponent("Tic.app")
        guard let newInfo = Self.info(of: new) else { throw Failure.badArchive }
        let installedID = Self.info(of: app)?["CFBundleIdentifier"] as? String
        guard let id = newInfo["CFBundleIdentifier"] as? String, id == installedID else { throw Failure.wrongApp }
        let found = newInfo["CFBundleShortVersionString"] as? String ?? "?"
        guard found == version else { throw Failure.wrongVersion(found) }
        guard await Self.run("/usr/bin/codesign", "--verify", "--strict", new.path) else { throw Failure.badSignature }

        // Two renames (old copy aside, new one in), restoring the old copy if the second fails. Plain
        // moves rather than `replaceItemAt`, which carries the old copy's metadata onto the new one.
        let old = staging.appendingPathComponent("old.app")
        try files.moveItem(at: app, to: old)
        do {
            try files.moveItem(at: new, to: app)
        } catch {
            try? files.moveItem(at: old, to: app)
            throw error
        }
    }

    /// Reopens `app` once this process has exited. The shell outlives Tic, waits for its pid to go, and
    /// opens the (now updated) bundle; the path is passed as `$0` so it needs no quoting.
    static func relaunchAfterExit(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        process.arguments = ["-c", script, app.path]
        try? process.run()
    }

    private static func info(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// Runs a tool to completion without blocking a thread; true when it exits 0.
    private static func run(_ tool: String, _ arguments: String...) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
    }
}
