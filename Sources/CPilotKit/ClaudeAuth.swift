// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Signing Claude in on a server from this Mac, so nobody has to open a terminal there.
/// Either the account sign-in (a link to open here, then a code to paste back) or an API key kept in a private file on the server.
public enum ClaudeAuth {
    /// Where an API key lives on the server. Only Claude's own commands read it.
    public static let keyFile = "$HOME/.cpilot/claude.env"
    public static let sourceKey = "[ -f \"\(keyFile)\" ] && . \"\(keyFile)\"; "

    public static func isSignedIn(_ env: EnvironmentConfig) async -> Bool {
        let r = try? await Exec.with(env) { try await Shell.run("claude", ["auth", "status"], timeout: 30) }
        return r?.ok == true
    }

    /// Keeps the key in a file only its owner can read, never on a command line (those show in the server's process list).
    public static func saveAPIKey(_ key: String, on env: EnvironmentConfig) async throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !k.contains("\n") else { throw ShellError.failed(command: "key", status: 1, stderr: "Enter the API key.") }
        let script = "umask 077; mkdir -p \"$HOME/.cpilot\" && cat > \"\(keyFile)\""
        let r = try await Exec.with(env) { try await Shell.run("sh", ["-c", script], input: Data("export ANTHROPIC_API_KEY=\(SSH.quote(k))\n".utf8), timeout: 30) }
        guard r.ok else { throw ShellError.failed(command: "key", status: r.status, stderr: r.stderr) }
        guard await isSignedIn(env) else {
            _ = try? await Exec.with(env) { try await Shell.run("sh", ["-c", "rm -f \"\(keyFile)\""], timeout: 20) }
            throw ShellError.failed(command: "key", status: 1, stderr: "The server did not accept that key. Check it and try again.")
        }
    }

    public static func removeAPIKey(on env: EnvironmentConfig) async {
        _ = try? await Exec.with(env) { try await Shell.run("sh", ["-c", "rm -f \"\(keyFile)\""], timeout: 20) }
    }

    /// The sign-in link in `claude auth login`'s output. The link is wrapped in terminal escape codes, which are skipped.
    public static func loginURL(in output: String) -> URL? {
        guard let r = output.range(of: #"https://[^\s\u{07}\u{1B}]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[r]))
    }

    /// One sign-in on a server: start it, hand over the link, take the code, check it worked.
    public final class Login: @unchecked Sendable {
        private let env: EnvironmentConfig
        private var live: LiveProcess?
        private let lock = NSLock()
        private var text = ""
        public init(_ env: EnvironmentConfig) { self.env = env }

        /// Starts `claude auth login` on the server and returns the link to open here.
        public func begin() async throws -> URL {
            let l = try await Exec.with(env) { try Shell.spawn("claude", ["auth", "login"]) { [weak self] s in self?.append(s) } }
            live = l
            for _ in 0..<150 {
                if let u = ClaudeAuth.loginURL(in: output) { return u }
                try await Task.sleep(for: .milliseconds(200))
            }
            l.terminate()
            throw ShellError.failed(command: "login", status: 1, stderr: "The server did not give a sign-in link. Check that Claude is installed there.")
        }

        /// Gives the code from the browser page to the server and reports whether Claude is now signed in.
        public func finish(code: String) async -> Bool {
            let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let live, !c.isEmpty else { return false }
            live.send(c + "\n")
            let waited = Task { await live.wait() }
            Task { try? await Task.sleep(for: .seconds(30)); live.terminate() }
            _ = await waited.value
            return await ClaudeAuth.isSignedIn(env)
        }

        public func cancel() { live?.terminate() }
        private var output: String { lock.lock(); defer { lock.unlock() }; return text }
        private func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    }
}
