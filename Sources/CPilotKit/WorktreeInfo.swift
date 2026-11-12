// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What can be run in a worktree, read from the files it already has: the scripts of `package.json`, the targets of a `Makefile`, the recipes of a `justfile`. The chief pilot is given
/// these so it can tell the user exactly what to type in each worktree, and never has to guess a script name.
public enum ProjectScripts {
    /// Names that suggest a step a person is asked to take or a check worth running, most useful first.
    public static let keywords = ["approve", "guard", "verify", "check", "pentest", "typecheck", "lint", "test", "e2e", "format", "build"]

    public static func packageManager(lockfiles: Set<String>, packageManagerField: String?) -> String {
        if let f = packageManagerField?.lowercased() { for m in ["pnpm", "yarn", "bun", "npm"] where f.hasPrefix(m) { return m } }
        if lockfiles.contains("pnpm-lock.yaml") { return "pnpm" }
        if lockfiles.contains("yarn.lock") { return "yarn" }
        if lockfiles.contains("bun.lockb") || lockfiles.contains("bun.lock") { return "bun" }
        return "npm"
    }

    public struct Found: Equatable, Sendable {
        public var runner: String
        public var scripts: [String]
        public init(runner: String, scripts: [String]) { self.runner = runner; self.scripts = scripts }
    }

    /// The script names in a `package.json`, and the package manager that runs them.
    public static func node(packageJSON: String, lockfiles: Set<String>) -> Found? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(packageJSON.utf8))) as? [String: Any] else { return nil }
        let names = ((obj["scripts"] as? [String: Any]) ?? [:]).keys.sorted()
        guard !names.isEmpty else { return nil }
        return Found(runner: packageManager(lockfiles: lockfiles, packageManagerField: obj["packageManager"] as? String), scripts: names)
    }

    private static func names(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !n.hasPrefix("."), seen.insert(n).inserted { out.append(n) }
        }
        return out
    }

    /// Makefile targets (`name:`), not variable assignments (`name:=`) and not special targets (`.PHONY`).
    public static func make(_ text: String) -> Found? {
        let t = names(in: text, pattern: #"^([A-Za-z0-9][A-Za-z0-9_.\-]*)\s*:(?![=:])"#)
        return t.isEmpty ? nil : Found(runner: "make", scripts: t)
    }

    /// Justfile recipes (`name args:`), not settings or assignments (`name := value`).
    public static func just(_ text: String) -> Found? {
        let t = names(in: text, pattern: #"^@?([A-Za-z0-9][A-Za-z0-9_\-]*)(?:\s+[^:=\n]*)?:(?!=)"#)
        return t.isEmpty ? nil : Found(runner: "just", scripts: t)
    }

    /// The names worth showing: those that look like an approval, a guard or a check first, in the order of `keywords`, then the rest alphabetically, at most `limit`.
    public static func relevant(_ names: [String], limit: Int = 12) -> [String] {
        func rank(_ n: String) -> Int { keywords.firstIndex { n.lowercased().contains($0) } ?? keywords.count }
        let matching = names.filter { rank($0) < keywords.count }
        return Array(matching.sorted { (rank($0), $0) < (rank($1), $1) }.prefix(limit))
    }

    /// What to type to run a script with its runner.
    public static func command(_ found: Found, _ script: String) -> String {
        switch found.runner {
        case "make", "just": return "\(found.runner) \(script)"
        default: return "\(found.runner) run \(script)"
        }
    }
}

/// `git status --porcelain=v1` as three lists.
public struct GitStatusSummary: Equatable, Sendable {
    public var staged: [String]
    public var unstaged: [String]
    public var untracked: [String]
    public var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }

    /// `git status --porcelain=v1` (one line each) or, better, `-z` (NUL-separated, never quoted). With `-z` a rename carries its old name as a separate entry, which is skipped.
    public static func parse(_ porcelain: String) -> GitStatusSummary {
        var s = GitStatusSummary(staged: [], unstaged: [], untracked: [])
        func add(_ x: Character, _ y: Character, _ path: String) {
            if x == "?" { s.untracked.append(path); return }
            if x != " " { s.staged.append(path) }
            if y != " " { s.unstaged.append(path) }
        }
        if porcelain.contains("\0") {
            var skip = false
            for entry in porcelain.split(separator: "\0") {
                if skip { skip = false; continue }
                guard entry.count > 3 else { continue }
                let x = entry[entry.startIndex], y = entry[entry.index(after: entry.startIndex)]
                add(x, y, String(entry.dropFirst(3)))
                if x == "R" || x == "C" || y == "R" || y == "C" { skip = true }
            }
        } else {
            for line in porcelain.split(whereSeparator: \.isNewline) where line.count > 3 {
                add(line[line.startIndex], line[line.index(after: line.startIndex)], unquote(String(line.dropFirst(3))))
            }
        }
        return s
    }

    /// git writes a path with a space or odd character as "a b.txt" with C-style escapes.
    static func unquote(_ p: String) -> String {
        guard p.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") else { return p }
        return String(p.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

public enum WorktreeCommands {
    /// The commands worth offering for one worktree, each ready to type from anywhere (`cd <worktree> && …`): look at what is staged or changed, then the scripts that look like a step to take.
    public static func suggestions(path: String, status: GitStatusSummary, scripts: [Found]) -> [String] {
        func q(_ s: String) -> String { s.contains(" ") ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s }
        let cd = "cd \(q(path)) && "
        var out: [String] = []
        if !status.staged.isEmpty { out.append(cd + "git diff --cached --stat"); out.append(cd + "git diff --cached") }
        if !status.unstaged.isEmpty || !status.untracked.isEmpty { out.append(cd + "git status --short") }
        for f in scripts { for s in ProjectScripts.relevant(f.scripts, limit: 8) { out.append(cd + ProjectScripts.command(f, s)) } }
        return out
    }
    public typealias Found = ProjectScripts.Found
}
