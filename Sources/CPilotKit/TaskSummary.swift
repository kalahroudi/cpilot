// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a task that passed the gate comes to, on one screen: how much changed, what was run against it, and what is risky about it. It is written when
/// the gate passes, kept with the gate's record, and shown beside the task, so reviewing starts from the risks and not from the whole diff.
public struct TaskSummary: Codable, Equatable, Sendable {
    public enum Risk: String, Codable, Comparable, Sendable {
        case low, medium, high
        public static func < (a: Risk, b: Risk) -> Bool { a.order < b.order }
        private var order: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
        public var label: String { rawValue.capitalized }
    }

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var added: Int
        public var removed: Int
    }

    /// The commit the summary describes.
    public var head: String
    public var files: [File]
    public var additions: Int
    public var deletions: Int
    /// The verification commands that passed on this commit.
    public var verified: [String]
    public var risk: Risk
    /// Each reason the risk is not low, most serious first. Empty for a low risk.
    public var reasons: [String]
    /// How many times the gate sent the task back before it passed.
    public var attempts: Int

    public var headline: String {
        "\(files.count) file\(files.count == 1 ? "" : "s"), +\(additions) −\(deletions)"
    }

    /// The biggest changes first, for a short list.
    public var biggest: [File] { files.sorted { $0.added + $0.removed > $1.added + $1.removed }.prefix(5).map { $0 } }
}

public enum TaskSummarizer {
    /// Points for each reason; 4 or more is high and 2 or more is medium. The reasons are shown with the risk, so the number never has to be trusted.
    public static func summarize(diff: String, head: String, touches: [String], protected: [String], verified: [String], attempts: Int) -> TaskSummary {
        let parsed = DiffCheck.parse(diff)
        let files = parsed.map { TaskSummary.File(path: $0.path, added: $0.added.count, removed: $0.removed.count) }
        let counted = parsed.filter { !ScopeGuard.isGenerated($0.path) }
        let lines = counted.reduce(0) { $0 + $1.added.count + $1.removed.count }

        var found: [(points: Int, why: String)] = []
        func add(_ p: Int, _ why: String) { found.append((p, why)) }

        let flagged = ScopeGuard.flagged(diff: diff, touches: touches, protected: protected)
        if !flagged.isEmpty { add(4, "Changes protected files: \(list(flagged)).") }

        let manifests = parsed.map(\.path).filter(isDependencyManifest)
        if !manifests.isEmpty { add(2, "Changes what the project depends on (\(list(manifests))). Check that every new package is real and is the one meant.") }

        let sensitive = parsed.map(\.path).filter(isSensitive)
        if !sensitive.isEmpty { add(2, "Touches code that handles access or secrets: \(list(sensitive)).") }

        let schema = parsed.map(\.path).filter(isSchema)
        if !schema.isEmpty { add(2, "Changes the database schema or its migrations: \(list(schema)).") }

        let code = counted.filter { isSource($0.path) }
        if !code.isEmpty, !parsed.contains(where: { DiffCheck.isTest($0.path) }) { add(2, "Changes code but no test.") }

        if verified.isEmpty { add(2, "Nothing was run against it: the repository has no verification commands (`.cpilot/verify`) and the task names none.") }

        if lines > 1000 { add(2, "Large: \(lines) changed lines.") } else if lines > 400 { add(1, "Sizeable: \(lines) changed lines.") }
        if counted.count > 15 { add(1, "Spread over \(counted.count) files.") }

        let named = touches.filter { !$0.isEmpty }
        if !named.isEmpty {
            let outside = counted.map(\.path).filter { p in !ScopeGuard.named(p, named) && !DiffCheck.isTest(p) }
            if outside.count > 2 { add(1, "\(outside.count) files outside the ones the task names, such as \(list(outside)).") }
        }
        if attempts > 3 { add(1, "Needed \(attempts) tries to pass the gate.") }

        let score = found.reduce(0) { $0 + $1.points }
        let risk: TaskSummary.Risk = score >= 4 ? .high : score >= 2 ? .medium : .low
        return TaskSummary(head: head, files: files, additions: parsed.reduce(0) { $0 + $1.added.count }, deletions: parsed.reduce(0) { $0 + $1.removed.count },
                           verified: verified, risk: risk, reasons: found.sorted { $0.points > $1.points }.map(\.why), attempts: attempts)
    }

    private static func list(_ paths: [String]) -> String {
        paths.prefix(3).map { "`\($0)`" }.joined(separator: ", ") + (paths.count > 3 ? " and \(paths.count - 3) more" : "")
    }

    static func isDependencyManifest(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        return ["package.swift", "package.json", "podfile", "cartfile", "requirements.txt", "pyproject.toml", "pipfile", "go.mod", "cargo.toml", "gemfile", "build.gradle", "build.gradle.kts", "pom.xml", "composer.json"].contains(n)
            || (n.hasPrefix("requirements") && n.hasSuffix(".txt"))
    }

    static func isSensitive(_ path: String) -> Bool {
        let p = path.lowercased()
        guard !DiffCheck.isTest(path) else { return false }
        return ["auth", "crypto", "keychain", "password", "credential", "secret", "token", "permission", "oauth", "session-key", "signing"].contains { p.contains($0) }
    }

    static func isSchema(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".sql") || p.contains("/migrations/") || p.contains("/migrate/") || p.hasPrefix("migrations/") || p.hasSuffix("schema.prisma")
    }

    static func isSource(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["swift", "m", "mm", "c", "cc", "cpp", "h", "hpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt", "cs", "php", "scala", "sh"].contains(ext) && !DiffCheck.isTest(path)
    }
}
