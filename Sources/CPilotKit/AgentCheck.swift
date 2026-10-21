// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Checks that an agent really works on a machine: it starts, speaks to CPilot and is signed in. Never starts a sign-in itself.
public enum AgentCheck {
    public struct Result: Equatable, Sendable {
        public enum State: Equatable, Sendable { case ok, needsSignIn, failed }
        public var state: State
        public var detail: String
    }

    /// `agent` nil checks Claude. `env` nil checks this Mac.
    public static func run(_ agent: AcpAgentConfig?, on env: EnvironmentConfig?, timeout: TimeInterval = 60) async -> Result {
        guard let agent else { return await claude(on: env) }
        let cwd = env.map { $0.remoteHome } ?? NSHomeDirectory()
        let client = AcpClient(config: agent, cwd: URL(fileURLWithPath: cwd), environment: env) { _ in }
        client.signsInAutomatically = false
        defer { client.stop() }
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    try await client.start()
                    _ = try await client.newSession()
                    return Result(state: .ok, detail: "Started and signed in.")
                } catch AcpError.authRequired {
                    return Result(state: .needsSignIn, detail: "Starts, but is not signed in. Use it once in a session to sign in.")
                } catch {
                    return Result(state: .failed, detail: error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return Result(state: .failed, detail: "Did not answer within \(Int(timeout)) seconds.")
            }
            let first = await group.next() ?? Result(state: .failed, detail: "No answer.")
            group.cancelAll()
            return first
        }
    }

    static func claude(on env: EnvironmentConfig?) async -> Result {
        do {
            let v = try await Exec.with(env) { try await Shell.run("claude", ["--version"], timeout: 30) }
            guard v.ok else { return Result(state: .failed, detail: (v.stderr.isEmpty ? v.stdout : v.stderr).trimmingCharacters(in: .whitespacesAndNewlines)) }
            let a = try await Exec.with(env) { try await Shell.run("claude", ["auth", "status"], timeout: 30) }
            let ver = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return a.ok ? Result(state: .ok, detail: "\(ver), signed in.") : Result(state: .needsSignIn, detail: "\(ver), not signed in.")
        } catch { return Result(state: .failed, detail: error.localizedDescription) }
    }
}
