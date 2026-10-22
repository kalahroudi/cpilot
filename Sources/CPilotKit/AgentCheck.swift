// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Checks that an agent really works on a machine: it starts, speaks to CPilot and is signed in. `run` never starts a sign-in; `signIn` does.
public enum AgentCheck {
    public struct Result: Equatable, Sendable {
        public enum State: Equatable, Sendable { case ok, needsSignIn, notSetUp, failed }
        public var state: State
        public var detail: String
    }

    /// `agent` nil checks Claude. `env` nil checks this Mac. An agent that is not on the server yet is reported at once, not started.
    public static func run(_ agent: AcpAgentConfig?, on env: EnvironmentConfig?, timeout: TimeInterval = 60) async -> Result {
        guard let agent else { return await claude(on: env) }
        if let env, !(await Provisioner.ready(agent, on: env)) {
            return Result(state: .notSetUp, detail: "\(agent.name) is not set up on \(env.name) yet.")
        }
        return await start(agent, on: env, signIn: false, timeout: timeout)
    }

    /// Starts the agent's own sign-in (a key already in the environment, or its browser login) and reports whether it worked.
    public static func signIn(_ agent: AcpAgentConfig, on env: EnvironmentConfig?) async -> Result {
        await start(agent, on: env, signIn: true, timeout: AcpClient.signInTimeout + 30)
    }

    private static func start(_ agent: AcpAgentConfig, on env: EnvironmentConfig?, signIn: Bool, timeout: TimeInterval) async -> Result {
        let cwd = env.map { $0.remoteHome } ?? NSHomeDirectory()
        let client = AcpClient(config: agent, cwd: URL(fileURLWithPath: cwd), environment: env) { _ in }
        client.signsInAutomatically = signIn
        defer { client.stop() }
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    try await client.start()
                    _ = try await client.newSession()
                    return Result(state: .ok, detail: signIn ? "Signed in." : "Started and signed in.")
                } catch AcpError.authRequired(let said) {
                    let why = signIn ? said : "Starts, but is not signed in."
                    return Result(state: .needsSignIn, detail: why)
                } catch {
                    let log = client.recentLog.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    return Result(state: .failed, detail: log.isEmpty ? error.localizedDescription : "\(error.localizedDescription) \(log)")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                // Stopping the agent also ends the call above, which the group would otherwise wait on.
                client.stop()
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
            guard v.ok else { return Result(state: env == nil ? .failed : .notSetUp, detail: (v.stderr.isEmpty ? v.stdout : v.stderr).trimmingCharacters(in: .whitespacesAndNewlines)) }
            let a = try await Exec.with(env) { try await Shell.run("claude", ["auth", "status"], timeout: 30) }
            let ver = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return a.ok ? Result(state: .ok, detail: "\(ver), signed in.") : Result(state: .needsSignIn, detail: "\(ver), not signed in.")
        } catch { return Result(state: env == nil ? .failed : .notSetUp, detail: env == nil ? error.localizedDescription : "Claude is not installed on \(env!.name) yet.") }
    }
}
