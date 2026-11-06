import AppKit
import Network

/// `Tic --mcp`: the process every MCP client spawns. A dumb pipe between the client's stdio and the
/// running app's Unix socket — both sides speak newline-delimited JSON-RPC, so bytes pass untouched
/// and the real server (`MCPService`) lives in the app, next to the database observers. Launches Tic
/// when it isn't running; exits with a hint when the socket never appears (MCP is switched off).
enum MCPProxy {
    @MainActor
    static func run(socketPath: String = MCPService.socketPath) -> Never {
        if !FileManager.default.fileExists(atPath: socketPath) { launchTic() }
        connect(socketPath, attemptsLeft: 40)   // 40 × 250ms: a cold launch plus the DB open
        dispatchMain()
    }

    /// Connects, retrying while the socket is missing (Tic still starting) or refusing (a stale file).
    private static func connect(_ path: String, attemptsLeft: Int) {
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                pipe(connection)
            case .failed, .waiting:
                connection.cancel()
                guard attemptsLeft > 0 else {
                    die("Tic: MCP is off. Turn it on in Tic › Settings › AI Agents.")
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
                    connect(path, attemptsLeft: attemptsLeft - 1)
                }
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    private static func pipe(_ connection: NWConnection) {
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {           // the client closed our stdin: we're done
                handle.readabilityHandler = nil
                connection.cancel()
                exit(0)
            }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        receive(connection)
    }

    private static func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty { try? FileHandle.standardOutput.write(contentsOf: data) }
            if isComplete || error != nil { exit(0) }   // Tic quit or MCP was switched off
            receive(connection)
        }
    }

    /// The app bundle sits three levels above the executable (Tic.app/Contents/MacOS/Tic). A bare
    /// `swift run` binary has no bundle, so in dev Tic simply has to be running already.
    @MainActor
    private static func launchTic() {
        guard let exe = Bundle.main.executableURL else { return }
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
    }

    private static func die(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        exit(1)
    }
}
