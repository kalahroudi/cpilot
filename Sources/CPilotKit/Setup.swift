// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One thing the app needs before it is useful: a tool, a runtime, a first-run resource.
/// The setup screen renders these as a checklist and does everything it can by itself.
/// Whatever it cannot do (admin password, a licence click, a system permission) becomes a manual step
/// with a copyable command, so nothing is ever left as "go read the README".
public struct Prereq: Identifiable, Equatable, Sendable {
    public enum Install: Equatable, Sendable {
        case brew(String)               // `brew install <formula>`, automated
        case command(String)            // runs in the user's terminal (needs a password or a TTY)
        case link(String)               // a download page; the user does it, then presses "check again"
        case none                       // nothing to install; only detected (e.g. a first-run resource)
        public var isBrew: Bool { if case .brew = self { true } else { false } }
    }
    public let id: String
    public let title: String
    public let detail: String           // why it is needed, in one plain sentence
    public let install: Install
    public var isMet: Bool
    /// Nice to have, but CPilot works without it, so it never blocks the app.
    public var optional: Bool

    public init(id: String, title: String, detail: String, install: Install, isMet: Bool, optional: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.install = install; self.isMet = isMet; self.optional = optional
    }
}

public struct SetupState: Equatable, Sendable {
    public var items: [Prereq]
    public init(items: [Prereq]) { self.items = items }

    public static func detect() -> SetupState {
        var items: [Prereq] = [
            Prereq(id: "git", title: "Git", detail: "Tracks changes and branches. Installs with Apple's command line tools.",
                   install: .command("xcode-select --install"), isMet: Shell.find("git") != nil && Shell.find("xcrun") != nil),
            Prereq(id: "claude", title: "Claude command line", detail: "Runs Claude sessions. Install it, then sign in once by running claude in Terminal.",
                   install: .link("https://claude.com/product/claude-code"), isMet: Shell.find("claude") != nil),
            Prereq(id: "gh", title: "GitHub command line", detail: "Pull requests, repo setup and cloning. Then run gh auth login in Terminal.",
                   install: .brew("gh"), isMet: Shell.find("gh") != nil, optional: true),
            Prereq(id: "node", title: "Node.js", detail: "Runs ACP agent bridges and the security scan.",
                   install: .brew("node"), isMet: Shell.find("node") != nil, optional: true),
        ]
        if !items.contains(where: { !$0.isMet && $0.install.isBrew }) { /* Homebrew is only needed when something below uses it */ }
        else { items.insert(Prereq(id: "brew", title: "Homebrew", detail: "Installs the command line tools this app uses.",
                                   install: .command(homebrewInstallCommand), isMet: Shell.find("brew") != nil), at: 0) }
        return SetupState(items: items)
    }

    public var missing: [Prereq] { items.filter { !$0.isMet } }
    /// Only required items block the app.
    public var ready: Bool { missing.allSatisfy(\.optional) }
    public var brewFormulae: [String] { missing.compactMap { if case .brew(let f) = $0.install { f } else { nil } } }
    public var homebrewPresent: Bool { Shell.find("brew") != nil }
    /// Is there something the app can install by itself right now?
    public var canAutoInstall: Bool { !brewFormulae.isEmpty && homebrewPresent }
    /// One line the user can paste into Terminal to do the automated part by hand.
    public var manualCommand: String { brewFormulae.isEmpty ? "" : "brew install " + brewFormulae.joined(separator: " ") }

    /// The official Homebrew installer. It asks for a password, so it runs in a terminal, never silently.
    public static let homebrewInstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Runs `brew install` for the missing formulae and streams its output.
    public static func installMissing(_ formulae: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard !formulae.isEmpty else { return }
        let env = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        let status = try await Shell.stream("brew", ["install"] + formulae, env: env, onLine: onLine)
        if status != 0 { throw ShellError.failed(command: "brew install", status: status, stderr: "brew install \(formulae.joined(separator: " ")) failed. See the log for details.") }
    }
}
