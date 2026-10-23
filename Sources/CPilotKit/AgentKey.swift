// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An API key for an agent that only needs a key (DeepSeek's harness reads `DEEPSEEK_API_KEY`). It is kept in a file only its owner can read,
/// on the machine the agent runs on, and loaded by the shell that starts the agent, so it never appears on a command line.
public enum AgentKey {
    /// The environment variable an agent reads its key from, for agents CPilot knows.
    public static func variable(for agentId: String) -> String? {
        ["deepseek-harness": "DEEPSEEK_API_KEY"][agentId]
    }

    static func safe(_ id: String) -> String { AgentInstaller.safeName(id) }
    /// Resolved by the shell on the machine, not here.
    public static func file(for agentId: String) -> String { "$HOME/.cpilot/keys/\(safe(agentId)).env" }

    /// The agent, started through a shell that loads its key file first. Agents without a known key are left as they are.
    public static func wrap(_ c: AcpAgentConfig) -> AcpAgentConfig {
        guard variable(for: c.id) != nil else { return c }
        var w = c
        w.command = "sh"
        w.args = ["-c", "[ -f \"\(file(for: c.id))\" ] && . \"\(file(for: c.id))\"; exec \"$@\"", "agent-key", c.command] + c.args
        return w
    }

    public static func isSaved(for agentId: String, on env: EnvironmentConfig?) async -> Bool {
        let r = try? await Exec.with(env) { try await Shell.run("sh", ["-c", "test -s \"\(file(for: agentId))\""], timeout: 20) }
        return r?.ok == true
    }

    public static func save(_ key: String, for agent: AcpAgentConfig, on env: EnvironmentConfig?) async throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = variable(for: agent.id) else { throw ShellError.failed(command: "key", status: 1, stderr: "\(agent.name) does not take an API key.") }
        guard !k.isEmpty, !k.contains("\n") else { throw ShellError.failed(command: "key", status: 1, stderr: "Enter the API key.") }
        let script = "umask 077; mkdir -p \"$HOME/.cpilot/keys\" && cat > \"\(file(for: agent.id))\""
        let r = try await Exec.with(env) { try await Shell.run("sh", ["-c", script], input: Data("export \(name)=\(SSH.quote(k))\n".utf8), timeout: 30) }
        guard r.ok else { throw ShellError.failed(command: "key", status: r.status, stderr: r.stderr) }
    }

    public static func remove(for agentId: String, on env: EnvironmentConfig?) async {
        _ = try? await Exec.with(env) { try await Shell.run("sh", ["-c", "rm -f \"\(file(for: agentId))\""], timeout: 20) }
    }
}
