// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ProvisionStep: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case pending, running, done, skipped, failed }
    public var id: String
    public var title: String
    public var state: State = .pending
    /// The latest line of output while running, or the reason when it failed.
    public var detail: String = ""
}

/// Gets a new server ready for sessions: installs the Claude command line (and Node.js when it is needed) in the user's home
/// folder, so no admin rights are needed, and copies the helper when the server keeps sessions running. Each step is reported as it happens.
public enum Provisioner {
    static let claudeNativeScript = """
    export PATH="$HOME/.local/bin:$HOME/.cpilot/claude/bin:$PATH"
    command -v claude >/dev/null 2>&1 && exit 0
    URL=https://claude.ai/install.sh
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" | bash
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL" | bash
    else echo "Neither curl nor wget is on the server, so Claude could not be downloaded." >&2; exit 1; fi
    command -v claude >/dev/null 2>&1
    """

    /// Used when the native installer does not work on this server (for example an unsupported system).
    static let claudeNpmScript = """
    export PATH="$HOME/.cpilot/node/bin:$HOME/.cpilot/claude/bin:$PATH"
    npm install -g --prefix "$HOME/.cpilot/claude" @anthropic-ai/claude-code && command -v claude >/dev/null 2>&1
    """

    /// Whether `agent` can already run on the server.
    static func ready(_ agent: AcpAgentConfig, on env: EnvironmentConfig) async -> Bool {
        let probe: String
        if AgentInstaller.installedVersion(of: agent) != nil {
            probe = "test -x \"" + AgentInstaller.onServer(agent, home: "$HOME").command + "\""
        } else { probe = "command -v " + SSH.quote(agent.command) + " >/dev/null 2>&1" }
        let r = try? await Exec.with(env) { try await Shell.run("sh", ["-c", probe], timeout: 30) }
        return r?.ok == true
    }

    /// What is missing on the server and could be installed without admin rights: Claude, every agent the user has connected, the helper.
    public static func plan(_ env: EnvironmentConfig, _ r: EnvironmentReport, agents: [AcpAgentConfig] = []) async -> [ProvisionStep] {
        var steps: [ProvisionStep] = []
        if !r.has("claude") { steps.append(ProvisionStep(id: "claude", title: "Install Claude")) }
        for a in agents where !(await ready(a, on: env)) { steps.append(ProvisionStep(id: "agent:" + a.id, title: "Install \(a.name)")) }
        if env.persistent, !(await Exec.with(env) { await RemoteHost.isInstalled() }) { steps.append(ProvisionStep(id: "helper", title: "Install the helper that keeps sessions running")) }
        return steps
    }

    static let uvInstallScript = """
    export PATH="$HOME/.local/bin:$PATH"
    command -v uvx >/dev/null 2>&1 && exit 0
    URL=https://astral.sh/uv/install.sh
    if command -v curl >/dev/null 2>&1; then curl -LsSf "$URL" | sh
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL" | sh
    else echo "Neither curl nor wget is on the server, so uv could not be downloaded." >&2; exit 1; fi
    command -v uvx >/dev/null 2>&1
    """

    /// The registry's name for the server's platform, from `uname -sm`.
    static func platform(_ uname: String) -> String? {
        let p = uname.lowercased().split(separator: " ").map(String.init)
        guard p.count >= 2 else { return nil }
        let arch = ["x86_64", "amd64"].contains(p[1]) ? "x86_64" : (["aarch64", "arm64"].contains(p[1]) ? "aarch64" : nil)
        guard let arch, ["linux", "darwin"].contains(p[0]) else { return nil }
        return "\(p[0])-\(arch)"
    }

    /// Downloads, checks and unpacks a native agent into the server's ~/.cpilot/agents.
    static func binaryScript(_ b: BinaryDistribution, dest: String) -> String {
        let archive = b.archive.absoluteString
        let isZip = b.archive.lastPathComponent.lowercased().hasSuffix(".zip")
        let sum = b.sha256.map { """
        GOT=$( (sha256sum "$TMP/a" 2>/dev/null || shasum -a 256 "$TMP/a") | cut -d' ' -f1 )
        [ "$GOT" = \(SSH.quote($0)) ] || { echo "The download does not match the registry's checksum, so it was not installed." >&2; exit 1; }
        """ } ?? ""
        return """
        set -e
        DEST=\(dest)
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        if command -v curl >/dev/null 2>&1; then curl -fsSL \(SSH.quote(archive)) -o "$TMP/a"
        elif command -v wget >/dev/null 2>&1; then wget -qO "$TMP/a" \(SSH.quote(archive))
        else echo "Neither curl nor wget is on the server." >&2; exit 1; fi
        \(sum)
        mkdir -p "$TMP/x"
        \(isZip ? "command -v unzip >/dev/null 2>&1 || { echo \"unzip is not on the server.\" >&2; exit 1; }\nunzip -q \"$TMP/a\" -d \"$TMP/x\"" : "tar -xf \"$TMP/a\" -C \"$TMP/x\"")
        chmod +x "$TMP/x/\(b.cmd.hasPrefix("./") ? String(b.cmd.dropFirst(2)) : b.cmd)"
        rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"; mv "$TMP/x" "$DEST"
        """
    }

    /// The step list, shared with the threads that report output.
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [ProvisionStep]
        private let onUpdate: @Sendable ([ProvisionStep]) -> Void
        init(_ steps: [ProvisionStep], _ onUpdate: @escaping @Sendable ([ProvisionStep]) -> Void) { self.steps = steps; self.onUpdate = onUpdate; onUpdate(steps) }
        var all: [ProvisionStep] { lock.lock(); defer { lock.unlock() }; return steps }
        func set(_ id: String, _ state: ProvisionStep.State, _ detail: String = "") {
            lock.lock()
            if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state; steps[i].detail = detail }
            let copy = steps
            lock.unlock()
            onUpdate(copy)
        }
    }

    /// Runs the plan on `env`. `onUpdate` receives the full step list whenever anything changes. Returns a fresh report.
    public static func run(_ env: EnvironmentConfig, report: EnvironmentReport, agents: [AcpAgentConfig] = [], onUpdate: @escaping @Sendable ([ProvisionStep]) -> Void) async -> (EnvironmentReport, [ProvisionStep]) {
        let t = Tracker(await plan(env, report, agents: agents), onUpdate)
        for step in t.all {
            t.set(step.id, .running, "Connecting…")
            do {
                switch step.id {
                case "claude": try await installClaude(env) { t.set("claude", .running, $0) }
                case let id where id.hasPrefix("agent:"):
                    guard let a = agents.first(where: { "agent:" + $0.id == id }) else { break }
                    try await installAgent(a, on: env) { t.set(id, .running, $0) }
                case "helper": try await Exec.with(env) { try await RemoteHost.install() }
                default: break
                }
                t.set(step.id, .done)
            } catch {
                t.set(step.id, .failed, error.localizedDescription)
            }
        }
        let fresh = await EnvironmentProbe.check(env)
        if fresh.connected, t.all.contains(where: { $0.id == "claude" && $0.state == .done }), !fresh.has("claude") {
            t.set("claude", .failed, "Claude installed but is still not found on the server's PATH.")
        }
        return (fresh, t.all)
    }

    static func run(_ script: String, on env: EnvironmentConfig, progress: @escaping @Sendable (String) -> Void) async throws -> (code: Int32, last: String) {
        final class Tail: @unchecked Sendable { var last = "" }
        let tail = Tail()
        let code = try await Exec.with(env) {
            try await Shell.stream("sh", ["-c", script]) { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.isEmpty else { return }
                tail.last = l; progress(l)
            }
        }
        return (code, tail.last)
    }

    /// Makes `agent` runnable on the server: its runtime (Node.js or uv), its download, or a clear message when it is a custom command.
    static func installAgent(_ agent: AcpAgentConfig, on env: EnvironmentConfig, progress: @escaping @Sendable (String) -> Void) async throws {
        func fail(_ why: String) -> ShellError { .failed(command: "install", status: 1, stderr: why) }
        if let version = AgentInstaller.installedVersion(of: agent) {
            progress("Checking the server…")
            let u = try await run("uname -sm", on: env, progress: { _ in })
            guard let platform = platform(u.last) else { throw fail("\(agent.name) has no download for this server (\(u.last)).") }
            progress("Looking up the download…")
            let all = await AcpRegistry.load(platform: platform)
            guard let b = all.first(where: { $0.id == agent.id })?.binary else { throw fail("\(agent.name) has no download for \(platform).") }
            progress("Downloading \(agent.name)…")
            let r = try await run(binaryScript(b, dest: "\"" + AgentInstaller.serverFolder(id: agent.id, version: version, home: "$HOME") + "\""), on: env, progress: progress)
            guard r.code == 0 else { throw fail("\(agent.name) could not be installed: \(r.last)") }
            return
        }
        switch agent.command {
        case "npx":
            progress("Installing Node.js…")
            let r = try await run(RemoteHost.nodeInstallScript, on: env, progress: progress)
            guard r.code == 0 else { throw fail("Node.js could not be installed, and \(agent.name) needs it. \(r.last)") }
        case "uvx":
            progress("Installing uv…")
            let r = try await run(uvInstallScript, on: env, progress: progress)
            guard r.code == 0 else { throw fail("uv could not be installed, and \(agent.name) needs it. \(r.last)") }
        default:
            throw fail("\(agent.name) runs “\(agent.command)”, which is not on the server. Install it there, then check again.")
        }
    }

    static func installClaude(_ env: EnvironmentConfig, progress: @escaping @Sendable (String) -> Void) async throws {
        func sh(_ script: String, _ what: String) async throws -> Bool {
            final class Tail: @unchecked Sendable { var lines: [String] = [] }
            let tail = Tail()
            let code = try await Exec.with(env) {
                try await Shell.stream("sh", ["-c", script]) { line in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { return }
                    tail.lines.append(l); progress(l)
                }
            }
            if code != 0, let last = tail.lines.last { progress("\(what) failed: \(last)") }
            return code == 0
        }
        progress("Downloading Claude…")
        if try await sh(claudeNativeScript, "Installer") { return }
        progress("The standard installer did not work here, trying npm…")
        guard try await sh(RemoteHost.nodeInstallScript, "Node.js") else {
            throw ShellError.failed(command: "install", status: 1, stderr: "Claude could not be installed automatically. Install it on the server (curl -fsSL https://claude.ai/install.sh | bash), then check again.")
        }
        guard try await sh(claudeNpmScript, "npm") else {
            throw ShellError.failed(command: "install", status: 1, stderr: "Claude could not be installed automatically. Install it on the server (curl -fsSL https://claude.ai/install.sh | bash), then check again.")
        }
    }
}
