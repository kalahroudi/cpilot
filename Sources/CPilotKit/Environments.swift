// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A machine that owns agents, files and git for its projects. "This Mac" is implicit; every other environment is reached over SSH.
/// Nothing needs installing on the server except the agents. With `persistent` on, a small helper (`cpilotd`) also keeps
/// agents running when the connection drops.
public struct EnvironmentConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Addresses to try in order: an alias from ~/.ssh/config, `user@host`, or a Tailscale name.
    public var routes: [String]
    public var port: Int?
    public var identityFile: String?
    /// Folders on the server where sessions may start.
    public var folders: [String]
    public var persistent: Bool
    /// Home folder on the server, learned when connecting.
    public var home: String?
    /// Which route last worked.
    public var active: Int?

    public init(id: String = UUID().uuidString, name: String, routes: [String], port: Int? = nil, identityFile: String? = nil,
                folders: [String] = [], persistent: Bool = false, home: String? = nil) {
        self.id = id; self.name = name; self.routes = routes; self.port = port; self.identityFile = identityFile
        self.folders = folders; self.persistent = persistent; self.home = home
    }

    public var target: String { routes.isEmpty ? name : routes[min(active ?? 0, routes.count - 1)] }
    public var remoteHome: String { home ?? "~" }

    public static func load(from url: URL = AppPaths().environmentsFile) -> [EnvironmentConfig] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([EnvironmentConfig].self, from: $0) } ?? []
    }

    public static func save(_ list: [EnvironmentConfig], to url: URL = AppPaths().environmentsFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(list) { try? d.write(to: url, options: .atomic) }
    }
}

/// Run a block "on" an environment: every `Shell` command inside it goes to that server instead of this Mac.
public enum Exec {
    @TaskLocal public static var environment: EnvironmentConfig?
    /// Trust a host key the first time it is seen (never one that changed). Only set while adding an environment.
    @TaskLocal public static var acceptNewHostKeys = false

    public static func with<T>(_ env: EnvironmentConfig?, _ body: () async throws -> T) async rethrows -> T {
        try await $environment.withValue(env) { try await body() }
    }
}

/// How CPilot talks SSH. It uses the `ssh` that ships with macOS, so your keys, agent, ~/.ssh/config and Tailscale all just work.
public enum SSH {
    public static var executable = "/usr/bin/ssh"

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Options every connection uses. One master connection is shared, so repeated commands are fast.
    public static func baseArgs(_ e: EnvironmentConfig, acceptNewHostKeys: Bool = false, connectTimeout: Int = 10) -> [String] {
        var a = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                 "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cpilot-%C", "-o", "ControlPersist=600"]
        if acceptNewHostKeys { a += ["-o", "StrictHostKeyChecking=accept-new"] }
        if let p = e.port { a += ["-p", String(p)] }
        if let i = e.identityFile, !i.isEmpty { a += ["-i", i] }
        return a
    }

    /// The command line the server runs: a login shell, so PATH matches what you get when you sign in there.
    public static func remoteCommand(_ tool: String, _ args: [String], cwd: String?, env: [String: String] = [:]) -> String {
        var inner = cwd.map { "cd \(quote($0)) && " } ?? ""
        inner += "exec "
        if !env.isEmpty { inner += "env " + env.sorted { $0.key < $1.key }.map { "\($0.key)=\(quote($0.value))" }.joined(separator: " ") + " " }
        inner += ([tool] + args).map(quote).joined(separator: " ")
        return "bash -lc " + quote(inner)
    }

    /// Hosts named in ~/.ssh/config (wildcards skipped), for the "Add environment" picker.
    public static func configuredHosts(configPath: String = NSHomeDirectory() + "/.ssh/config") -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("host ") else { continue }
            for h in line.dropFirst(5).split(whereSeparator: \.isWhitespace) where !h.contains("*") && !h.contains("?") && !h.hasPrefix("!") && !out.contains(String(h)) { out.append(String(h)) }
        }
        return out
    }
}

public struct EnvironmentReport: Equatable, Sendable {
    public var connected = false
    public var error: String?
    public var home: String?
    public var tools: [String: String] = [:]
    public var gitHubSignedIn = false
    public func has(_ t: String) -> Bool { tools[t] != nil }
}

public enum EnvironmentProbe {
    /// Connects and looks for what sessions need, so anything missing can be explained before the first session.
    public static func check(_ env: EnvironmentConfig, acceptNewHostKeys: Bool = false) async -> EnvironmentReport {
        var report = EnvironmentReport()
        let script = "for t in claude git gh node docker; do p=$(command -v $t 2>/dev/null) && echo \"tool:$t=$p\"; done; echo \"home=$HOME\"; gh auth status >/dev/null 2>&1 && echo gh_auth=1; true"
        guard let r = try? await Exec.$acceptNewHostKeys.withValue(acceptNewHostKeys, operation: { try await Exec.with(env, { try await Shell.run("sh", ["-c", script], timeout: 25) }) }) else { report.error = "Could not start ssh."; return report }
        guard r.ok, r.stdout.contains("home=") else {
            report.error = describe(r.stderr.isEmpty ? r.stdout : r.stderr)
            return report
        }
        report.connected = true
        for l in r.stdout.components(separatedBy: "\n") {
            if l.hasPrefix("tool:"), let eq = l.firstIndex(of: "=") { report.tools[String(l[l.index(l.startIndex, offsetBy: 5)..<eq])] = String(l[l.index(after: eq)...]) }
            else if l.hasPrefix("home=") { report.home = String(l.dropFirst(5)) }
            else if l == "gh_auth=1" { report.gitHubSignedIn = true }
        }
        return report
    }

    /// Plain-language reasons for the common SSH failures.
    public static func describe(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") { return "The server's host key is not trusted, or it changed. Connect once in Terminal to check it: ssh \(stderr.isEmpty ? "host" : "…")" }
        if s.contains("permission denied") { return "The server did not accept your key. Add your public key to ~/.ssh/authorized_keys on the server, or pick the right key in the environment's settings." }
        if s.contains("timed out") || s.contains("no route") || s.contains("could not resolve") || s.contains("connection refused") { return "Could not reach the server. Check the address and that it is online." }
        let first = stderr.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "Could not connect." : first
    }

    /// Tries each route in order and remembers the first that works.
    public static func connect(_ env: EnvironmentConfig, acceptNewHostKeys: Bool = false) async -> (EnvironmentConfig, EnvironmentReport) {
        var e = env
        var last = EnvironmentReport(); last.error = "No address to connect to."
        for (i, _) in e.routes.enumerated() {
            e.active = i
            let r = await check(e, acceptNewHostKeys: acceptNewHostKeys)
            if r.connected { e.home = r.home; return (e, r) }
            last = r
        }
        return (env, last)
    }
}
