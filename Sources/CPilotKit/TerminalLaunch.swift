// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How to start a command in a session's folder, in the app's own terminal or in Ghostty.
public enum TerminalLaunch {
    public static let ghosttyApp = "/Applications/Ghostty.app"
    public static var ghosttyInstalled: Bool { FileManager.default.fileExists(atPath: ghosttyApp) }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell line: go to the folder, run the command, then stay in a shell there so the output can be read and the app tried again.
    public static func script(directory: String, command: String) -> String {
        "cd \(quote(directory)) && \(RunnableCommands.shellLine(command)); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// A program and arguments that run the command, locally or on the session's server.
    public static func argv(directory: String, command: String, env: EnvironmentConfig?) -> (executable: String, args: [String]) {
        let line = script(directory: directory, command: command)
        if let e = env {
            return (SSH.executable, ["-t"] + (e.port.map { ["-p", String($0)] } ?? []) + [e.target, quote(line)])
        }
        return ("/bin/zsh", ["-l", "-c", line])
    }

    /// Arguments for `open` that start a new Ghostty window running the command in the folder.
    public static func ghosttyOpenArgs(directory: String, command: String, env: EnvironmentConfig?) -> [String] {
        let a = argv(directory: directory, command: command, env: env)
        return ["-na", ghosttyApp, "--args", "--working-directory=" + (env == nil ? directory : NSHomeDirectory()), "-e", a.executable] + a.args
    }
}
