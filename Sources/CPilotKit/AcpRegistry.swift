// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An agent listed in the official ACP registry. Agents that ship as an npm or Python package run through npx or uvx;
/// native downloads are fetched, checked and unpacked by CPilot itself (`AgentInstaller`).
public struct RegistryAgent: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var version: String = ""
    public var config: AcpAgentConfig?          // nil when there is no package to run
    public var needsRuntime: String?            // "npx" or "uvx"
    public var binary: BinaryDistribution?      // a download for this Mac, when the agent ships as one
}

/// A native agent's download for one platform, as the registry describes it.
public struct BinaryDistribution: Equatable, Sendable {
    public var archive: URL
    public var cmd: String                      // relative to the unpacked folder, for example "./goose"
    public var args: [String]
    public var env: [String: String]
    public var sha256: String?
}

public enum AcpRegistry {
    public static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    /// The registry's name for this Mac's platform.
    public static var platform: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    public static func parse(_ data: Data, platform: String = AcpRegistry.platform) -> [RegistryAgent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let agents = root["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { a -> RegistryAgent? in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            let detail = (a["description"] as? String) ?? ""
            let dist = (a["distribution"] as? [String: Any]) ?? [:]
            let version = (a["version"] as? String) ?? ""
            func make(_ kind: String, _ command: String, _ leading: [String]) -> AcpAgentConfig? {
                guard let d = dist[kind] as? [String: Any], let pkg = d["package"] as? String else { return nil }
                return AcpAgentConfig(id: id, name: name, command: command, args: leading + [pkg] + ((d["args"] as? [String]) ?? []),
                                      env: (d["env"] as? [String: String]) ?? [:])
            }
            if let c = make("npx", "npx", ["-y"]) { return RegistryAgent(id: id, name: name, detail: detail, version: version, config: c, needsRuntime: "npx") }
            if let c = make("uvx", "uvx", []) { return RegistryAgent(id: id, name: name, detail: detail, version: version, config: c, needsRuntime: "uvx") }
            var binary: BinaryDistribution?
            if let all = dist["binary"] as? [String: Any], let b = all[platform] as? [String: Any],
               let archive = (b["archive"] as? String).flatMap(URL.init(string:)), archive.scheme == "https", let cmd = b["cmd"] as? String {
                binary = BinaryDistribution(archive: archive, cmd: cmd, args: (b["args"] as? [String]) ?? [], env: (b["env"] as? [String: String]) ?? [:],
                                            sha256: (b["sha256"] as? String)?.lowercased())
            }
            return RegistryAgent(id: id, name: name, detail: detail, version: version, config: nil, needsRuntime: nil, binary: binary)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Agents that speak ACP but are not in the registry (yet). Versions are pinned to one that was tried with CPilot.
    public static let extras: [RegistryAgent] = [
        RegistryAgent(id: "deepseek-harness", name: "DeepSeek Harness (dsh)",
                      detail: "DeepSeek's open-source agent harness, served over ACP by `dsh --profile acp`. Set up its model provider and key with dsh itself.",
                      version: "0.2.1-rc.2",
                      config: AcpAgentConfig(id: "deepseek-harness", name: "DeepSeek Harness (dsh)", command: "npx", args: ["-y", "@deepseek-ai/dsh@0.2.1-rc.2", "--profile", "acp"]),
                      needsRuntime: "npx"),
    ]

    /// The registry's agents plus the extras it does not list, by name.
    public static func withExtras(_ agents: [RegistryAgent]) -> [RegistryAgent] {
        let have = Set(agents.map(\.id))
        return (agents + extras.filter { !have.contains($0.id) }).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fetches the registry, falling back to the last copy saved on disk when offline.
    public static func load() async -> [RegistryAgent] {
        let cache = AppPaths().root.appendingPathComponent("registry.json")
        if let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 {
            let parsed = parse(data)
            if !parsed.isEmpty { try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true); try? data.write(to: cache) }
            return withExtras(parsed)
        }
        return withExtras((try? Data(contentsOf: cache)).map { parse($0) } ?? [])
    }
}
