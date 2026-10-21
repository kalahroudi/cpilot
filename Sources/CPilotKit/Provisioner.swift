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

    /// What is missing on the server and could be installed without admin rights.
    public static func plan(_ env: EnvironmentConfig, _ r: EnvironmentReport) async -> [ProvisionStep] {
        var steps: [ProvisionStep] = []
        if !r.has("claude") { steps.append(ProvisionStep(id: "claude", title: "Install Claude")) }
        if env.persistent, !(await Exec.with(env) { await RemoteHost.isInstalled() }) { steps.append(ProvisionStep(id: "helper", title: "Install the helper that keeps sessions running")) }
        return steps
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
    public static func run(_ env: EnvironmentConfig, report: EnvironmentReport, onUpdate: @escaping @Sendable ([ProvisionStep]) -> Void) async -> (EnvironmentReport, [ProvisionStep]) {
        let t = Tracker(await plan(env, report), onUpdate)
        for step in t.all {
            t.set(step.id, .running, "Connecting…")
            do {
                switch step.id {
                case "claude": try await installClaude(env) { t.set("claude", .running, $0) }
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
