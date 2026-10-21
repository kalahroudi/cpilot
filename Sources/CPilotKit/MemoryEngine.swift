// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Optional long-term memory for sessions, served by a memory engine that speaks MCP over HTTP.
/// CPilot's own notes (plain Markdown files) always work with nothing installed. An engine adds recall across sessions:
/// the session gets its retain, recall and reflect tools, one memory bank per project.
public enum MemoryEngine {
    public static let defaultURL = "http://localhost:8888"

    /// One bank per project, named like the project's notes folder.
    public static func bank(forProject path: String) -> String { MemoryStore.scope(forProject: path) }

    public static func mcpURL(base: String, bank: String) -> String {
        base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/mcp/" + bank + "/"
    }

    /// The JSON the Claude command line accepts for `--mcp-config`.
    public static func claudeConfig(base: String, bank: String) -> String {
        let o: [String: Any] = ["mcpServers": ["memory": ["type": "http", "url": mcpURL(base: base, bank: bank)]]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The `mcpServers` entry ACP agents take in `session/new`.
    public static func acpServers(base: String, bank: String) -> [[String: Any]] {
        [["type": "http", "name": "memory", "url": mcpURL(base: base, bank: bank), "headers": [[String: String]]()]]
    }

    public static func isReachable(base: String) async -> Bool {
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return code < 500
    }

    /// Starts the engine in Docker with its own embedded database. It needs an LLM to extract memories; the example uses an API key,
    /// and the engine's own docs list providers that need none.
    public static let dockerCommand = "docker run -d --name hindsight --restart unless-stopped -p 8888:8888 -p 9999:9999 -e HINDSIGHT_API_LLM_API_KEY=$OPENAI_API_KEY -v hindsight-data:/home/hindsight/.pg0 ghcr.io/vectorize-io/hindsight:latest"
}
