// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An agent listed in the official ACP registry. Agents that ship as an npm or Python package can be added in one click;
/// native downloads are listed but need installing by hand.
public struct RegistryAgent: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var config: AcpAgentConfig?          // nil when there is no package to run
    public var needsRuntime: String?            // "npx" or "uvx"
}

public enum AcpRegistry {
    public static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    public static func parse(_ data: Data) -> [RegistryAgent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let agents = root["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { a -> RegistryAgent? in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            let detail = (a["description"] as? String) ?? ""
            let dist = (a["distribution"] as? [String: Any]) ?? [:]
            func make(_ kind: String, _ command: String, _ leading: [String]) -> AcpAgentConfig? {
                guard let d = dist[kind] as? [String: Any], let pkg = d["package"] as? String else { return nil }
                return AcpAgentConfig(id: id, name: name, command: command, args: leading + [pkg] + ((d["args"] as? [String]) ?? []),
                                      env: (d["env"] as? [String: String]) ?? [:])
            }
            if let c = make("npx", "npx", ["-y"]) { return RegistryAgent(id: id, name: name, detail: detail, config: c, needsRuntime: "npx") }
            if let c = make("uvx", "uvx", []) { return RegistryAgent(id: id, name: name, detail: detail, config: c, needsRuntime: "uvx") }
            return RegistryAgent(id: id, name: name, detail: detail, config: nil, needsRuntime: nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fetches the registry, falling back to the last copy saved on disk when offline.
    public static func load() async -> [RegistryAgent] {
        let cache = AppPaths().root.appendingPathComponent("registry.json")
        if let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 {
            let parsed = parse(data)
            if !parsed.isEmpty { try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true); try? data.write(to: cache) }
            return parsed
        }
        return (try? Data(contentsOf: cache)).map(parse) ?? []
    }
}
