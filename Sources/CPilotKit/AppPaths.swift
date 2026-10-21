// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Every file the app owns lives under one folder, so uninstalling is deleting it.
/// Never scatter state across ~/.something, /tmp and UserDefaults without listing it here.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CPilot", isDirectory: true)
    }

    public var updateDir: URL { root.appendingPathComponent("update", isDirectory: true) }
    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var memoryDir: URL { root.appendingPathComponent("memory", isDirectory: true) }
    public var capturesDir: URL { root.appendingPathComponent("captures", isDirectory: true) }
    public var toolsDir: URL { root.appendingPathComponent("tools", isDirectory: true) }
    public var auditFile: URL { root.appendingPathComponent("audit.jsonl") }
    public var policyFile: URL { root.appendingPathComponent("policy.json") }
    public var agentsFile: URL { root.appendingPathComponent("agents.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Written by the running app so the MCP server can find it (loopback port + token), 0600.
    public var controlFile: URL { root.appendingPathComponent("control.json") }

    public func ensureDirectories() throws {
        for dir in [root, updateDir, sessionsDir, memoryDir, capturesDir, toolsDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
}
