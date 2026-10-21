// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DaemonStatus: Decodable, Equatable, Sendable {
    public var running: Bool
    public var exit: Int?
    public var signal: String?
    public var error: String?
    public var lines: Int?
    public var missing: Bool?
}

/// Talks to `cpilotd` on a server, through whatever environment is active in `Exec`.
public enum RemoteHost {
    /// Where the helper lives on the server. A shell variable, so it resolves there, not here.
    nonisolated(unsafe) public static var scriptLocation = "$HOME/.cpilot/cpilotd.mjs"

    /// The command that runs the helper with `args`.
    public static func command(_ args: [String]) -> (tool: String, args: [String]) {
        ("sh", ["-c", "exec node \"\(scriptLocation)\" \"$@\"", "cpilotd"] + args)
    }

    public static func isInstalled() async -> Bool {
        let c = command(["version"])
        guard let r = try? await Shell.run(c.tool, c.args, timeout: 20), r.ok else { return false }
        return r.stdout.contains("cpilotd \(Cpilotd.version)")
    }

    /// Copies the helper to the server. It needs Node.js there; if it is missing the error says how to get it.
    public static func install() async throws {
        let node = try await Shell.run("sh", ["-c", "command -v node >/dev/null 2>&1 && echo yes || echo no"], timeout: 20)
        guard node.stdout.contains("yes") else {
            throw ShellError.failed(command: "install", status: 1, stderr: "The server needs Node.js to keep sessions running. Install it there (for example: sudo apt install nodejs, or brew install node), then try again.")
        }
        let dest = scriptLocation
        let dirScript = "mkdir -p \"$(dirname \"\(dest)\")\" && cat > \"\(dest)\" && chmod 700 \"\(dest)\""
        let r = try await Shell.run("sh", ["-c", dirScript], input: Data(Cpilotd.source.utf8), timeout: 30)
        guard r.ok else { throw ShellError.failed(command: "install", status: r.status, stderr: r.stderr) }
        guard await isInstalled() else { throw ShellError.failed(command: "install", status: 1, stderr: "The helper was copied but did not start. Check that Node.js 18 or newer is installed on the server.") }
    }

    public static func start(id: String, cwd: String, command cmd: String, args: [String]) async throws {
        let c = command(["start", id, "--cwd", cwd, "--", cmd] + args)
        let r = try await Shell.run(c.tool, c.args, timeout: 30)
        guard r.ok, r.stdout.contains("\"ok\":true") else {
            let msg = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["error"] as? String
            throw ShellError.failed(command: "start", status: r.status, stderr: msg ?? (r.stderr.isEmpty ? "The agent could not be started." : r.stderr))
        }
    }

    public static func status(id: String) async -> DaemonStatus? {
        let c = command(["status", id])
        guard let r = try? await Shell.run(c.tool, c.args, timeout: 20), r.ok else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: Data(r.stdout.utf8))
    }

    public static func stop(id: String) async {
        let c = command(["stop", id])
        _ = try? await Shell.run(c.tool, c.args, timeout: 20)
    }
}
