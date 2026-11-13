// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// Which files of a repository a security or bug-hunting pass should read, so a provider is paid only for what changed or has not been looked at.
public enum ScanScope {
    static let skippedDirs: Set<String> = ["node_modules", "vendor", "dist", "build", "out", ".build", "Pods", "DerivedData", "target", "coverage", ".next", ".git", "__pycache__", "third_party", "bower_components"]
    static let skippedNames: Set<String> = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Package.resolved", "Cargo.lock", "go.sum", "poetry.lock", "Gemfile.lock", "composer.lock", "bun.lockb"]
    static let skippedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "svg", "pdf", "mp4", "mov", "woff", "woff2", "ttf", "otf", "zip", "gz", "tar", "map", "snap", "min.js", "lock", "wasm", "bin", "dylib", "o", "a"]

    /// Whether a file is worth sending: source and configuration, not generated, vendored, binary or locked files.
    public static func included(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: skippedDirs.contains) { return false }
        if skippedNames.contains(name) { return false }
        let lower = name.lowercased()
        if lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") || lower.hasSuffix(".generated.swift") || lower.hasSuffix(".pb.go") { return false }
        let ext = (lower as NSString).pathExtension
        return !skippedExtensions.contains(ext)
    }
}

/// Where bugs that matter live, judged from a path alone, so a limited budget goes to the riskiest files first. A heuristic, not a verdict.
public enum RiskRank {
    static let weights: [(String, Int)] = [("auth", 5), ("login", 4), ("session", 4), ("token", 4), ("password", 5), ("secret", 4), ("crypto", 5), ("sign", 2), ("permission", 4), ("policy", 3), ("acl", 3), ("rbac", 3),
                                           ("sql", 4), ("query", 2), ("migration", 2), ("exec", 4), ("shell", 4), ("spawn", 3), ("upload", 4), ("download", 2), ("parse", 3), ("deserial", 5), ("serializ", 3),
                                           ("middleware", 3), ("route", 3), ("handler", 3), ("controller", 3), ("webhook", 4), ("oauth", 5), ("payment", 5), ("billing", 4), ("admin", 4), ("guard", 3), ("sanitiz", 4), ("escape", 2), ("cors", 3), ("csrf", 4)]

    public static func score(_ path: String) -> Int {
        let lower = path.lowercased()
        var s = weights.reduce(0) { lower.contains($1.0) ? $0 + $1.1 : $0 }
        if lower.contains("test") || lower.contains("spec.") || lower.contains("/docs/") || lower.contains("fixture") || lower.contains("mock") { s = max(0, s - 6) }
        return s
    }

    public static func ordered(_ paths: [String]) -> [String] { paths.sorted { (score($0), $1) > (score($1), $0) } }
}

/// What a scan of one file at one content hash with one prompt and model found, kept so the same question is never paid for twice. Nothing but names, counts and a short summary is kept.
public final class ScanLedger: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var repo: String, path: String, hash: String, prompt: String, model: String
        public var findings: Int
        public var tokensIn: Int, tokensOut: Int
        public var summary: String
        public init(repo: String, path: String, hash: String, prompt: String, model: String, findings: Int, tokensIn: Int = 0, tokensOut: Int = 0, summary: String = "") {
            self.repo = repo; self.path = path; self.hash = hash; self.prompt = prompt; self.model = model; self.findings = findings; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.summary = summary
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Files to send, riskiest first.
        public var todo: [String]
        /// Files already scanned at this content with this prompt and model, and the findings they gave.
        public var reused: [String]
        public var reusedFindings: Int
        /// Files left out of scope (generated, vendored, binary, locked).
        public var skipped: Int
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL = AppPaths().root.appendingPathComponent("scans.db")) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS scans(repo TEXT, path TEXT, hash TEXT, prompt TEXT, model TEXT, findings INT, tin INT, tout INT, summary TEXT, ts REAL, PRIMARY KEY(repo, path, hash, prompt, model))", nil, nil, nil)
    }

    deinit { if let db { sqlite3_close(db) } }

    public func record(_ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard db != nil, sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO scans(repo,path,hash,prompt,model,findings,tin,tout,summary,ts) VALUES(?,?,?,?,?,?,?,?,?,?)", -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        for (i, v) in [e.repo, e.path, e.hash, e.prompt, e.model].enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, Self.transient) }
        sqlite3_bind_int64(st, 6, Int64(e.findings)); sqlite3_bind_int64(st, 7, Int64(e.tokensIn)); sqlite3_bind_int64(st, 8, Int64(e.tokensOut))
        sqlite3_bind_text(st, 9, String(e.summary.prefix(500)), -1, Self.transient); sqlite3_bind_double(st, 10, Date().timeIntervalSince1970)
        sqlite3_step(st)
    }

    public func lookup(repo: String, path: String, hash: String, prompt: String, model: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard db != nil, sqlite3_prepare_v2(db, "SELECT findings,tin,tout,summary FROM scans WHERE repo=? AND path=? AND hash=? AND prompt=? AND model=?", -1, &st, nil) == SQLITE_OK, let st else { return nil }
        defer { sqlite3_finalize(st) }
        for (i, v) in [repo, path, hash, prompt, model].enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, Self.transient) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return Entry(repo: repo, path: path, hash: hash, prompt: prompt, model: model, findings: Int(sqlite3_column_int64(st, 0)), tokensIn: Int(sqlite3_column_int64(st, 1)),
                     tokensOut: Int(sqlite3_column_int64(st, 2)), summary: sqlite3_column_text(st, 3).map { String(cString: $0) } ?? "")
    }

    /// What to send for a repository at its present content. `files` maps each path to its content hash (git's blob id). A changed file has a new hash, so it is scanned again;
    /// a new prompt version or another model starts afresh, because the answer would differ.
    public func plan(repo: String, files: [String: String], prompt: String, model: String) -> Plan {
        var todo: [String] = [], reused: [String] = [], findings = 0, skipped = 0
        for (path, hash) in files {
            guard ScanScope.included(path) else { skipped += 1; continue }
            if let e = lookup(repo: repo, path: path, hash: hash, prompt: prompt, model: model) { reused.append(path); findings += e.findings } else { todo.append(path) }
        }
        return Plan(todo: RiskRank.ordered(todo), reused: reused.sorted(), reusedFindings: findings, skipped: skipped)
    }
}

public enum GitBlobs {
    /// Parses `git ls-tree -r <ref>`: `<mode> blob <hash>\t<path>`. The hash is git's own content id, so no file is read to know whether it changed.
    public static func parse(_ lsTree: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in lsTree.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let meta = line[..<tab].split(separator: " ")
            guard meta.count == 3, meta[1] == "blob" else { continue }
            out[String(line[line.index(after: tab)...])] = String(meta[2])
        }
        return out
    }
}
