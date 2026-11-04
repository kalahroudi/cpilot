// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Hard limits for sessions that work without you watching (the tasks and reviewers the chief pilot starts, and triggers). They hold whatever access
/// level the session has, Full access included, because nobody is there to answer a card. A denial tells the agent why, so it can take another route.
public enum ToolGuards {
    public static func appliesTo(_ m: SessionMeta) -> Bool { ["task", "reviewer", "trigger"].contains(Guardrails.source(of: m)) }

    /// Why this tool call must not run, or nil. `exceptions` are names or path prefixes the user allowed (a dependency bump may edit a lockfile).
    public static func violation(tool: String, summary: String, path: String?, root: String, exceptions: [String] = []) -> String? {
        if AccessPolicy.editTools.contains(tool), let path, let hit = protectedPath(path, root: root, exceptions: exceptions) {
            return "\(hit) is protected: unattended work does not change it. If the task really needs this, finish everything else and say so in your summary."
        }
        if tool == "Bash" { return commandViolation(summary, root: root, exceptions: exceptions) }
        return nil
    }

    // MARK: Paths

    static let lockfiles: Set<String> = ["Package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "Gemfile.lock", "poetry.lock", "Podfile.lock", "go.sum", "composer.lock", "bun.lockb"]

    /// A readable name for what a path is protected as, or nil when it is not protected. The path may be absolute or relative to `root`.
    public static func protectedPath(_ path: String, root: String, exceptions: [String] = []) -> String? {
        let abs = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardized.path : URL(fileURLWithPath: root).appendingPathComponent(path).standardized.path
        let base = URL(fileURLWithPath: root).standardized.path
        let rel = abs.hasPrefix(base + "/") ? String(abs.dropFirst(base.count + 1)) : abs
        if exceptions.contains(where: { rel == $0 || rel.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") || (rel as NSString).lastPathComponent == $0 }) { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        if rel.hasPrefix(".github/workflows/") || rel == ".github/workflows" { return "`\(rel)` (CI workflows)" }
        if rel == ".cpilot" || rel.hasPrefix(".cpilot/") { return "`\(rel)` (CPilot's own files)" }
        if parts.contains(".git") { return "`\(rel)` (git's own files)" }
        if name == ".env" || (name.hasPrefix(".env.") && !["example", "sample", "template", "defaults"].contains(where: { name.hasSuffix(".\($0)") })) { return "`\(rel)` (secrets)" }
        if lockfiles.contains(name) { return "`\(rel)` (a lockfile)" }
        return nil
    }

    // MARK: Commands

    /// Folders `rm -r` may remove: they are rebuilt by the next build.
    static let buildFolders: Set<String> = [".build", "build", "dist", "node_modules", "target", "DerivedData", ".next", "out", "coverage", ".cache", "__pycache__", ".pytest_cache", ".gradle"]
    /// Hosts a command may fetch from: package registries and the project's own forge.
    static let hosts = ["github.com", "api.github.com", "raw.githubusercontent.com", "objects.githubusercontent.com", "registry.npmjs.org", "registry.yarnpkg.com", "crates.io", "static.crates.io", "index.crates.io", "pypi.org", "files.pythonhosted.org", "proxy.golang.org", "sum.golang.org", "swift.org", "download.swift.org", "rubygems.org", "localhost", "127.0.0.1"]
    static let systemCommands: Set<String> = ["sudo", "doas", "mkfs", "shutdown", "reboot", "halt", "launchctl", "networksetup", "diskutil", "csrutil", "spctl", "scutil", "systemsetup", "pmset", "dscl"]

    /// Splits a command line into the commands it runs, in order. Quotes are not understood on purpose: a word inside quotes is checked as if it were bare, which can only deny more.
    static func segments(_ command: String) -> [[String]] {
        command.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n").replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }.filter { !$0.isEmpty }
    }

    public static func commandViolation(_ command: String, root: String = "", exceptions: [String] = []) -> String? {
        if command.range(of: #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|node|ruby|perl)\b"#, options: .regularExpression) != nil {
            return "Piping a download into a shell is not allowed. Download it to a file you can read first, or use the project's package manager."
        }
        for var words in segments(command) {
            // Leading `VAR=value` and `env` do not change what runs.
            while let f = words.first, f.contains("="), !f.hasPrefix("-"), !f.hasPrefix("/") { words.removeFirst() }
            if words.first == "env" || words.first == "command" || words.first == "time" { words.removeFirst() }
            guard let cmd = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let args = Array(words.dropFirst())
            if systemCommands.contains(cmd) { return "`\(cmd)` changes the machine, not the project, and is not allowed here." }
            switch cmd {
            case "git":
                if let why = gitViolation(args) { return why }
            case "rm":
                if let why = rmViolation(args) { return why }
            case "curl", "wget":
                if let why = fetchViolation(args) { return why }
            case "chmod", "chown":
                if args.contains("-R") || args.contains("777") { return "`\(cmd)` on a whole tree or with 777 is not allowed here." }
            case "defaults":
                if args.first == "write" || args.first == "delete" { return "`defaults \(args.first!)` changes the machine's settings and is not allowed here." }
            case "npm", "pnpm", "yarn":
                if args.contains("-g") || args.contains("--global") { return "A global install changes the machine, not the project. Install it into the project instead." }
            case "dd":
                if args.contains(where: { $0.hasPrefix("of=/dev") }) { return "Writing to a device is not allowed." }
            default: break
            }
        }
        if let why = protectedWrite(command, root: root, exceptions: exceptions) { return why }
        return nil
    }

    private static func gitViolation(_ args: [String]) -> String? {
        var i = 0
        while i < args.count, args[i].hasPrefix("-") { i += args[i] == "-C" || args[i] == "-c" ? 2 : 1 }
        guard i < args.count else { return nil }
        let sub = args[i]
        if sub == "push", args.contains(where: { $0 == "-f" || $0 == "--force" || $0.hasPrefix("--force-with-lease") || $0 == "--delete" || $0 == "-d" || $0.hasPrefix("+") || $0 == "--mirror" }) {
            return "Force-pushing and deleting remote branches are not allowed. Push normally; if it is rejected, `git pull --rebase` and push again."
        }
        if sub == "config", args.contains("--global") || args.contains("--system") { return "Changing git's global settings is not allowed here." }
        return nil
    }

    private static func rmViolation(_ args: [String]) -> String? {
        let flags = args.filter { $0.hasPrefix("-") }
        let recursive = flags.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R"))) }
        guard recursive else { return nil }
        let targets = args.filter { !$0.hasPrefix("-") }
        if targets.isEmpty { return nil }
        for t in targets {
            var p = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            while p.hasPrefix("./") { p.removeFirst(2) }
            let parts = p.split(separator: "/").map(String.init)
            let safe = !p.hasPrefix("/") && !p.hasPrefix("~") && !p.hasPrefix("$") && !parts.contains("..") && !p.contains("*") && (parts.first.map(buildFolders.contains) ?? false)
            if !safe { return "`rm -r` is only allowed on build folders (\(buildFolders.sorted().prefix(4).joined(separator: ", ")) and the like). To remove tracked files use `git rm`." }
        }
        return nil
    }

    private static func fetchViolation(_ args: [String]) -> String? {
        for arg in args where !arg.hasPrefix("-") {
            let bare = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let hasScheme = bare.contains("://")
            let rest = bare.replacingOccurrences(of: #"^\w+://"#, with: "", options: .regularExpression)
            // Without a scheme only something shaped like a host counts; `out.zip` after `-o` is a file name.
            guard hasScheme || rest.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?(/|$)"#, options: .regularExpression) != nil,
                  hasScheme || rest.range(of: #"\.(txt|json|zip|tgz|gz|tar|sh|log|out|html|pdf|png)$"#, options: .regularExpression) == nil else { continue }
            let host = (rest.split(whereSeparator: { "/:?".contains($0) }).first.map(String.init) ?? "").lowercased()
            if host.isEmpty || hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { continue }
            return "Downloading from `\(host)` is not allowed. Package registries and GitHub are; for anything else, say what you need in your summary."
        }
        return nil
    }

    /// A shell command that writes to, moves or removes a protected path.
    private static func protectedWrite(_ command: String, root: String, exceptions: [String]) -> String? {
        let writes = command.contains(">") || command.range(of: #"\b(tee|rm|mv|cp|sed\s+-i|truncate|chmod|touch|install)\b"#, options: .regularExpression) != nil
        guard writes, !root.isEmpty else { return nil }
        for word in command.split(whereSeparator: { " \t\n;&|<>()=".contains($0) }).map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }) where !word.isEmpty && !word.hasPrefix("-") {
            if let hit = protectedPath(word, root: root, exceptions: exceptions) { return "\(hit) is protected: unattended work does not change it with shell commands either." }
        }
        return nil
    }
}
