// SPDX-License-Identifier: MIT

import Foundation

/// AI agents that can use the cpilot MCP server, and how to connect them.
public enum AgentKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, claudeDesktop, cursor, windsurf, geminiCLI, codexCLI
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .geminiCLI: "Gemini CLI"
        case .codexCLI: "Codex CLI"
        }
    }

    /// Desktop editors read their MCP config only at launch.
    public var needsRestart: Bool { self == .claudeDesktop || self == .cursor || self == .windsurf }
}

public struct AgentStatus: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notDetected
        case available                    // agent found, cpilot not connected
        case connected                    // cpilot entry present and pointing at the current server
        case outdated(String)             // entry points somewhere else (app moved or renamed)
    }
    public let kind: AgentKind
    public var state: State
    public var id: String { kind.rawValue }
    public var detected: Bool { state != .notDetected }
}

public enum AgentIntegrations {
    public static let serverName = "cpilot"

    /// Where the MCP server lives: inside the installed app, or the bundle that is running now.
    public static func serverPath(bundlePath: String = Bundle.main.bundlePath) -> String {
        bundlePath.hasSuffix(".app") ? bundlePath + "/Contents/MacOS/cpilot-mcp" : "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp"
    }

    // MARK: Locations

    static func home(_ rel: String) -> URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel) }

    /// JSON config file for agents that keep MCP servers under "mcpServers".
    public static func configURL(_ kind: AgentKind) -> URL? {
        switch kind {
        case .claudeCode: home(".claude.json")
        case .claudeDesktop: home("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: home(".cursor/mcp.json")
        case .windsurf: home(".codeium/windsurf/mcp_config.json")
        case .geminiCLI: home(".gemini/settings.json")
        case .codexCLI: nil   // TOML, see codexConfigURL
        }
    }
    public static var codexConfigURL: URL { home(".codex/config.toml") }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Is the agent itself on this Mac?
    public static func isDetected(_ kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode: Shell.find("claude") != nil || exists(home(".claude").path)
        case .claudeDesktop: exists("/Applications/Claude.app") || exists(home("Applications/Claude.app").path) || exists(home("Library/Application Support/Claude").path)
        case .cursor: exists("/Applications/Cursor.app") || exists(home("Applications/Cursor.app").path) || exists(home(".cursor").path)
        case .windsurf: exists("/Applications/Windsurf.app") || exists(home(".codeium/windsurf").path)
        case .geminiCLI: Shell.find("gemini") != nil || exists(home(".gemini").path)
        case .codexCLI: Shell.find("codex") != nil || exists(home(".codex").path)
        }
    }

    // MARK: Scan

    public static func scan(serverPath: String = serverPath()) -> [AgentStatus] {
        AgentKind.allCases.map { kind in
            guard isDetected(kind) else { return AgentStatus(kind: kind, state: .notDetected) }
            let entry = kind == .codexCLI ? codexCommand() : configURL(kind).flatMap { jsonCommand(at: $0) }
            switch entry {
            case nil: return AgentStatus(kind: kind, state: .available)
            case let c? where c == serverPath: return AgentStatus(kind: kind, state: .connected)
            case let c?: return AgentStatus(kind: kind, state: .outdated(c))
            }
        }
    }

    // MARK: JSON configs

    /// The command registered for cpilot in a JSON config, if any.
    public static func jsonCommand(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// Adds (or updates) the cpilot entry and keeps everything else in the file. A one-time backup is kept next to it.
    public static func jsonInstall(at url: URL, command: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ShellError.failed(command: "update \(url.lastPathComponent)", status: 1, stderr: "\(url.path) is not a JSON object, so it was left unchanged.")
            }
            root = obj
            let backup = url.appendingPathExtension("cpilot-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": command]
        root["mcpServers"] = servers
        try write(root, to: url)
    }

    public static func jsonRemove(at url: URL) throws {
        guard let data = try? Data(contentsOf: url), var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any], servers[serverName] != nil else { return }
        servers.removeValue(forKey: serverName)
        root["mcpServers"] = servers
        try write(root, to: url)
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // MARK: Codex (TOML)

    /// The command of [mcp_servers.cpilot] in Codex's config.toml, if present.
    public static func codexCommand(at url: URL = codexConfigURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[mcp_servers.\(serverName)]"; continue }
            if inSection, line.hasPrefix("command"), let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                return String(line[line.index(after: q1)..<q2])
            }
        }
        return nil
    }

    // MARK: Install / remove

    /// Connects an agent. Uses the agent's own CLI where it has one, otherwise edits its config file.
    public static func install(_ kind: AgentKind, serverPath: String = serverPath()) async throws {
        guard FileManager.default.isExecutableFile(atPath: serverPath) else {
            throw ShellError.failed(command: "connect", status: 1, stderr: "The MCP server was not found at \(serverPath). Install CPilot into Applications first.")
        }
        switch kind {
        case .claudeCode:
            if Shell.find("claude") != nil {
                _ = try? await Shell.run("claude", ["mcp", "remove", serverName, "--scope", "user"], timeout: 30)
                try await Shell.check("claude", ["mcp", "add", serverName, "--scope", "user", "--", serverPath], timeout: 30)
            } else { try jsonInstall(at: configURL(kind)!, command: serverPath) }
        case .codexCLI:
            guard Shell.find("codex") != nil else { throw ShellError.toolNotFound("codex") }
            _ = try? await Shell.run("codex", ["mcp", "remove", serverName], timeout: 30)
            try await Shell.check("codex", ["mcp", "add", serverName, "--", serverPath], timeout: 30)
        default:
            try jsonInstall(at: configURL(kind)!, command: serverPath)
        }
    }

    public static func remove(_ kind: AgentKind) async throws {
        switch kind {
        case .claudeCode:
            if Shell.find("claude") != nil { try await Shell.check("claude", ["mcp", "remove", serverName, "--scope", "user"], timeout: 30) }
            else { try jsonRemove(at: configURL(kind)!) }
        case .codexCLI: try await Shell.check("codex", ["mcp", "remove", serverName], timeout: 30)
        default: try jsonRemove(at: configURL(kind)!)
        }
    }
}
