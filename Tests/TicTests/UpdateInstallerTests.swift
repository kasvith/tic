import CryptoKit
import Foundation
import Testing
@testable import Tic

/// The in-place updater against real (fake) app bundles: each test installs a signed "Tic.app" into a
/// temp Applications folder, builds a release zip + checksum, and serves them through the injected
/// download. Every failure must leave the installed copy exactly as it was.
@Suite("UpdateInstaller")
struct UpdateInstallerTests {
    private struct Fixture {
        let folder: URL
        var installed: URL { folder.appendingPathComponent("Tic.app") }
    }

    private func makeFixture(installedVersion: String = "0.8.0") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = Fixture(folder: folder)
        try makeApp(at: fixture.installed, version: installedVersion)
        return fixture
    }

    /// A minimal, ad-hoc-signed bundle: Info.plist + a shell-script executable.
    private func makeApp(at app: URL, id: String = "com.kasvith.tic", version: String, tamper: Bool = false) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": id, "CFBundleExecutable": "Tic",
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Tic")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        if tamper { try Data("#!/bin/sh\necho changed\n".utf8).write(to: executable) }
    }

    /// A release: `Tic.zip` of a fresh bundle plus its `Tic.zip.sha256` (or a wrong one).
    private func makeRelease(id: String = "com.kasvith.tic", version: String, tamper: Bool = false, badChecksum: Bool = false) throws -> UpdateInstaller {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerBuild-\(UUID().uuidString)")
        let app = build.appendingPathComponent("Tic.app")
        try makeApp(at: app, id: id, version: version, tamper: tamper)
        let zipURL = build.appendingPathComponent("Tic.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zipURL.path)
        let zip = try Data(contentsOf: zipURL)
        let hash = badChecksum ? String(repeating: "0", count: 64) : SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let checksum = Data("\(hash)  Tic.zip\n".utf8)
        return UpdateInstaller(download: { url in
            url.lastPathComponent == "Tic.zip.sha256" ? checksum : zip
        })
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    private func installedVersion(_ fixture: Fixture) -> String? {
        (NSDictionary(contentsOf: fixture.installed.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    @Test("installs the new version in place and leaves nothing behind")
    func installs() async throws {
        let fixture = try makeFixture()
        try await makeRelease(version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        #expect(installedVersion(fixture) == "0.9.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path) == ["Tic.app"])
    }

    @Test("a checksum mismatch stops before touching the installed copy")
    func checksumMismatch() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
            try await makeRelease(version: "0.9.0", badChecksum: true).install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a download that isn't Tic is refused")
    func wrongApp() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.wrongApp) {
            try await makeRelease(id: "com.example.other", version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a download of another version than the one offered is refused")
    func wrongVersion() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.wrongVersion("0.9.1")) {
            try await makeRelease(version: "0.9.1").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("an app whose signature no longer matches is refused")
    func brokenSignature() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.badSignature) {
            try await makeRelease(version: "0.9.0", tamper: true).install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a folder Tic can't write to is reported, not attempted")
    func notWritable() async throws {
        let fixture = try makeFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path) }
        await #expect(throws: UpdateInstaller.Failure.notWritable(fixture.folder.path)) {
            try await makeRelease(version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }
}
