// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

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
    /// Sign in with a password kept in the macOS Keychain, instead of keys or Tailscale. SSH asks for it only when the server does.
    public var usesPassword: Bool?
    /// Home folder on the server, learned when connecting.
    public var home: String?
    /// Which route last worked.
    public var active: Int?
    /// How each agent runs on this server, where that differs from this Mac (a native download has its own arguments per platform). Set when CPilot installs it there.
    public var remoteAgents: [String: AcpAgentConfig]?

    public init(id: String = UUID().uuidString, name: String, routes: [String], port: Int? = nil, identityFile: String? = nil,
                folders: [String] = [], persistent: Bool = false, home: String? = nil, usesPassword: Bool? = nil) {
        self.id = id; self.name = name; self.routes = routes; self.port = port; self.identityFile = identityFile
        self.folders = folders; self.persistent = persistent; self.home = home; self.usesPassword = usesPassword
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
    /// Called once when ssh prints a Tailscale sign-in link ("requires an additional check"). The command keeps waiting for the approval.
    @TaskLocal public static var onAuthURL: (@Sendable (URL) -> Void)?

    public static func with<T>(_ env: EnvironmentConfig?, _ body: () async throws -> T) async rethrows -> T {
        try await $environment.withValue(env) { try await body() }
    }
}

/// How CPilot talks SSH. It uses the `ssh` that ships with macOS, so your keys, agent, ~/.ssh/config and Tailscale all just work.
public enum SSH {
    public static var executable = "/usr/bin/ssh"

    /// The program SSH runs to get a password: this app itself, started with `--askpass`.
    nonisolated(unsafe) public static var askpassExecutable = CommandLine.arguments.first ?? "CPilot"

    /// A tiny script SSH calls when it needs a password. It holds no secret; it asks the app, which reads the Keychain.
    public static func askpassScript() -> String {
        let dir = AppPaths().toolsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass.sh")
        let body = "#!/bin/sh\nexec \(quote(askpassExecutable)) --askpass \"$@\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != body { try? body.write(to: url, atomically: true, encoding: .utf8) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    /// The process environment for an ssh command: the normal one, plus the askpass settings when this server uses a password.
    public static func environment(for e: EnvironmentConfig) -> [String: String] {
        var env = Shell.environment
        if e.usesPassword == true {
            env["SSH_ASKPASS"] = askpassScript(); env["SSH_ASKPASS_REQUIRE"] = "force"; env["CPILOT_ASKPASS_ID"] = e.id
        }
        return env
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Options every connection uses. One master connection is shared, so repeated commands are fast.
    public static func baseArgs(_ e: EnvironmentConfig, acceptNewHostKeys: Bool = false, connectTimeout: Int = 10, shareConnection: Bool = true) -> [String] {
        // With a password SSH must be allowed to ask (through the askpass helper below); otherwise it never prompts.
        var a = ["-T", "-o", e.usesPassword == true ? "BatchMode=no" : "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                 ] + (shareConnection ? ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cpilot-%C", "-o", "ControlPersist=600"] : ["-o", "ControlMaster=no", "-o", "ControlPath=none"])
        if e.usesPassword == true { a += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "NumberOfPasswordPrompts=1"] }
        if acceptNewHostKeys { a += ["-o", "StrictHostKeyChecking=accept-new"] }
        if let p = e.port { a += ["-p", String(p)] }
        if let i = e.identityFile, !i.isEmpty { a += ["-i", i] }
        return a
    }

    /// The command line the server runs: a login shell, so PATH matches what you get when you sign in there.
    public static func remoteCommand(_ tool: String, _ args: [String], cwd: String?, env: [String: String] = [:]) -> String {
        // Tools CPilot installs for the user (Claude, Node.js) live in the home folder, which a login shell may not have on PATH.
        var inner = tool == "claude" ? ClaudeAuth.sourceKey : ""
        inner += "PATH=\"$HOME/.local/bin:$HOME/.cpilot/claude/bin:$HOME/.cpilot/node/bin:$PATH\"; export PATH; "
        inner += cwd.map { "cd \(quote($0)) && " } ?? ""
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
    /// Whether Claude on the server is signed in (an account or an API key). Only looked at when Claude is installed.
    public var claudeSignedIn = false
    public init(connected: Bool = false, error: String? = nil, home: String? = nil, tools: [String: String] = [:], gitHubSignedIn: Bool = false, claudeSignedIn: Bool = false) {
        self.connected = connected; self.error = error; self.home = home; self.tools = tools; self.gitHubSignedIn = gitHubSignedIn; self.claudeSignedIn = claudeSignedIn
    }
    public func has(_ t: String) -> Bool { tools[t] != nil }
}

/// Holds the first Tailscale approval link a connection printed.
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    var url: URL? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ u: URL) { lock.lock(); value = u; lock.unlock() }
}

public enum EnvironmentProbe {
    /// Connects and looks for what sessions need, so anything missing can be explained before the first session.
    public static func check(_ env: EnvironmentConfig, acceptNewHostKeys: Bool = false, onAuthURL: (@Sendable (URL) -> Void)? = nil) async -> EnvironmentReport {
        var report = EnvironmentReport()
        let script = "for t in claude git gh node docker; do p=$(command -v $t 2>/dev/null) && echo \"tool:$t=$p\"; done; echo \"home=$HOME\"; gh auth status >/dev/null 2>&1 && echo gh_auth=1; true"
        // Tailscale SSH can ask for a browser approval before it lets the command run. Remember the link so a timeout can say so,
        // and when someone is there to click it (a handler was given) wait long enough for them to.
        let seen = URLBox()
        let forward: @Sendable (URL) -> Void = { seen.set($0); onAuthURL?($0) }
        let wait: TimeInterval = onAuthURL == nil ? 25 : 150
        let result: ShellResult
        do {
            result = try await Exec.$onAuthURL.withValue(forward, operation: {
                try await Exec.$acceptNewHostKeys.withValue(acceptNewHostKeys, operation: { try await Exec.with(env, { try await Shell.run("sh", ["-c", script], timeout: wait) }) })
            })
        } catch {
            if let url = seen.url { report.error = "Tailscale needs you to approve this connection. Open \(url.absoluteString), approve it, then check again." }
            else if case ShellError.timedOut = error { report.error = "The server did not answer in time. Check the address and that it is online." }
            else { report.error = "Could not start ssh." }
            return report
        }
        let r = result
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
        if report.has("claude") { report.claudeSignedIn = await ClaudeAuth.isSignedIn(env) }
        return report
    }

    /// Plain-language reasons for the common SSH failures.
    public static func describe(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("tailnet policy does not permit") || (s.contains("tailscale") && s.contains("not permit")) {
            let user = stderr.range(of: #"as user \"([^\"]+)\""#, options: .regularExpression).map { String(stderr[$0]).replacingOccurrences(of: "as user ", with: "").replacingOccurrences(of: "\"", with: "") } ?? "that user"
            return "Tailscale does not allow SSH to this server as \(user). Enter the account your tailnet allows in the User field (for example moram), and leave Sign in with on Automatic."
        }
        if s.contains("tailscale") && (s.contains("check") || s.contains("authenticate") || s.contains("login.tailscale")) { return "Tailscale needs you to approve this connection in your browser. Open the link ssh printed, approve it, then check again." }
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") { return "The server's host key is not trusted, or it changed. Connect once in Terminal to check it: ssh \(stderr.isEmpty ? "host" : "…")" }
        if s.contains("permission denied") && s.contains("password") && !s.contains("publickey") { return "The server did not accept that password. Check the user and the password." }
        if s.contains("permission denied") { return "The server did not accept your key. Add your public key to ~/.ssh/authorized_keys on the server, or pick the right key in the environment's settings." }
        if s.contains("timed out") || s.contains("no route") || s.contains("could not resolve") || s.contains("connection refused") { return "Could not reach the server. Check the address and that it is online." }
        let first = stderr.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "Could not connect." : first
    }

    /// Tries each route in order and remembers the first that works.
    public static func connect(_ env: EnvironmentConfig, acceptNewHostKeys: Bool = false, onAuthURL: (@Sendable (URL) -> Void)? = nil) async -> (EnvironmentConfig, EnvironmentReport) {
        var e = env
        var last = EnvironmentReport(); last.error = "No address to connect to."
        for (i, _) in e.routes.enumerated() {
            e.active = i
            let r = await check(e, acceptNewHostKeys: acceptNewHostKeys, onAuthURL: onAuthURL)
            if r.connected { e.home = r.home; return (e, r) }
            last = r
        }
        return (env, last)
    }
}


/// SSH passwords live in the macOS Keychain, never in a file, a command line or an environment variable.
public enum SSHPassword {
    static let service = "CPilot SSH"

    @discardableResult
    public static func set(_ password: String, for id: String) -> Bool {
        delete(id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id,
                                kSecValueData as String: Data(password.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func get(_ id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete(_ id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
    }

    public static func has(_ id: String) -> Bool { get(id) != nil }
}
