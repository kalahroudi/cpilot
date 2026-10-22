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
        ("sh", ["-c", "PATH=\"$HOME/.cpilot/node/bin:$PATH\"; export PATH; exec node \"\(scriptLocation)\" \"$@\"", "cpilotd"] + args)
    }

    public static func isInstalled() async -> Bool {
        let c = command(["version"])
        guard let r = try? await Shell.run(c.tool, c.args, timeout: 20), r.ok else { return false }
        return r.stdout.contains("cpilotd \(Cpilotd.version)")
    }

    /// The oldest Node.js the agents CPilot runs through npx work with. Older ones start and exit without a word.
    static let minimumNode = 22

    /// Installs Node.js for this user under ~/.cpilot/node (no root needed) when the server has none, or has one older than `minimumNode`.
    static let nodeInstallScript = """
    export PATH="$HOME/.cpilot/node/bin:$PATH"
    MAJOR=$(node -v 2>/dev/null | sed 's/^v//; s/\\..*//')
    [ -n "$MAJOR" ] && [ "$MAJOR" -ge \(minimumNode) ] 2>/dev/null && exit 0
    V=v22.23.4
    case "$(uname -s)" in Linux) OS=linux;; Darwin) OS=darwin;; *) echo "Unsupported system $(uname -s)" >&2; exit 1;; esac
    case "$(uname -m)" in x86_64|amd64) A=x64;; aarch64|arm64) A=arm64;; armv7l) A=armv7l;; *) echo "Unsupported CPU $(uname -m)" >&2; exit 1;; esac
    URL="https://nodejs.org/dist/$V/node-$V-$OS-$A.tar.gz"
    DIR="$HOME/.cpilot/node"
    mkdir -p "$DIR" || exit 1
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" | tar -xz -C "$DIR" --strip-components=1
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL" | tar -xz -C "$DIR" --strip-components=1
    else echo "Neither curl nor wget is on the server, so Node.js could not be downloaded." >&2; exit 1; fi
    command -v node >/dev/null 2>&1 || { echo "Node.js did not install from $URL" >&2; exit 1; }
    """

    /// Copies the helper to the server, installing Node.js there first if it is missing.
    public static func install() async throws {
        let node = try await Shell.run("sh", ["-c", nodeInstallScript], timeout: 300)
        guard node.ok else {
            let why = node.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.failed(command: "install", status: node.status, stderr: "Node.js is missing on the server and could not be installed automatically. " + why)
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
