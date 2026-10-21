// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import NaturalLanguage

/// Turns text into a vector. The real one is Apple's on-device sentence embedding: no model download, no server, offline.
public protocol TextEmbedder: Sendable {
    func embed(_ text: String) -> [Float]?
}

public final class NLEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private let model = NLEmbedding.sentenceEmbedding(for: .english)
    public init() {}
    public var isAvailable: Bool { model != nil }
    public func embed(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let v = model?.vector(for: String(text.prefix(1000))) else { return nil }
        let f = v.map { Float($0) }
        let norm = sqrt(f.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? f.map { $0 / norm } : nil
    }
}

/// Local memory with recall: every note and every finished chat message becomes a small chunk in one SQLite file.
/// A search runs full-text matching (BM25) and meaning matching (vectors) side by side and merges the two rankings,
/// the same shape the large memory systems use, at a size that fits in a menu bar app. Nothing leaves your Mac.
public final class MemoryIndex: @unchecked Sendable {
    public struct Hit: Identifiable, Equatable, Sendable {
        public var id: Int64
        public var scope: String
        public var source: String       // "note" or "chat"
        public var ref: String          // note name or session id
        public var text: String
        public var score: Double
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let embedder: TextEmbedder?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL = AppPaths().root.appendingPathComponent("memory.db"), embedder: TextEmbedder? = NLEmbedder()) {
        self.embedder = embedder
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, scope TEXT NOT NULL, source TEXT NOT NULL, ref TEXT NOT NULL, ts REAL NOT NULL, text TEXT NOT NULL, vec BLOB)")
        exec("CREATE INDEX IF NOT EXISTS chunks_ref ON chunks(ref)")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, content='chunks', content_rowid='id')")
        exec("CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text); END")
        exec("CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text); END")
    }

    deinit { if let db { sqlite3_close(db) } }

    public var isOpen: Bool { db != nil }

    // MARK: Writing

    /// Obvious secrets never enter the index.
    public static func redact(_ s: String) -> String {
        s.replacingOccurrences(of: #"(sk-|ghp_|gho_|github_pat_|AKIA|xox[bp]-)[A-Za-z0-9_\-]{12,}"#, with: "[redacted]", options: .regularExpression)
    }

    /// Splits text into chunks of about `size` characters on paragraph and sentence boundaries.
    public static func chunks(_ text: String, size: Int = 600) -> [String] {
        var out: [String] = [], cur = ""
        for para in text.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if p.count > size {
                if !cur.isEmpty { out.append(cur); cur = "" }
                var piece = ""
                for sentence in p.split(separator: ".", omittingEmptySubsequences: true) {
                    let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines) + "."
                    if piece.count + s.count > size, !piece.isEmpty { out.append(piece); piece = "" }
                    piece += (piece.isEmpty ? "" : " ") + (s.count > size ? String(s.prefix(size)) : s)
                }
                if !piece.isEmpty { out.append(piece) }
            } else if cur.count + p.count + 2 > size { out.append(cur); cur = p }
            else { cur += (cur.isEmpty ? "" : "\n\n") + p }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public func add(scope: String, source: String, ref: String, text: String, ts: Date = .now) {
        let clean = Self.redact(text)
        for chunk in Self.chunks(clean) where chunk.count >= 12 { insert(scope: scope, source: source, ref: ref, ts: ts, text: chunk) }
    }

    /// Replaces everything stored for `ref` (used for notes, which change as you edit them).
    public func replace(scope: String, source: String, ref: String, text: String) {
        remove(ref: ref); add(scope: scope, source: source, ref: ref, text: text)
    }

    public func remove(ref: String) {
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM chunks WHERE ref = ?", [.text(ref)])
    }

    public func removeAll(source: String) {
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM chunks WHERE source = ?", [.text(source)])
    }

    private func insert(scope: String, source: String, ref: String, ts: Date, text: String) {
        let vec = embedder?.embed(text).map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM chunks WHERE ref = ? AND text = ?", [.text(ref), .text(text)])     // never store the same chunk twice
        run("INSERT INTO chunks(scope, source, ref, ts, text, vec) VALUES(?,?,?,?,?,?)",
            [.text(scope), .text(source), .text(ref), .double(ts.timeIntervalSince1970), .text(text), vec.map { .blob($0) } ?? .null])
    }

    // MARK: Reading

    public func counts() -> (notes: Int, chats: Int) {
        lock.lock(); defer { lock.unlock() }
        func n(_ source: String) -> Int { Int(scalar("SELECT COUNT(*) FROM chunks WHERE source = ?", [.text(source)]) ?? 0) }
        return (n("note"), n("chat"))
    }

    /// Best matches first. `scopes` limits where to look (a project plus the global notes); nil searches everything.
    public func search(_ query: String, scopes: [String]? = nil, limit: Int = 5, excludingRef: String? = nil) -> [Hit] {
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        guard !terms.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var rank: [Int64: Double] = [:]
        var rows: [Int64: Hit] = [:]
        let scopeSQL = scopes.map { " AND c.scope IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        let scopeArgs: [Value] = (scopes ?? []).map { .text($0) }

        // 1. Words (BM25). Prefix match so "tests" finds "testing".
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        let sql = "SELECT c.id, c.scope, c.source, c.ref, c.text FROM chunks_fts f JOIN chunks c ON c.id = f.rowid WHERE chunks_fts MATCH ?\(scopeSQL) ORDER BY bm25(chunks_fts) LIMIT 20"
        for (i, r) in fetch(sql, [.text(match)] + scopeArgs).enumerated() {
            guard let hit = hit(from: r), hit.ref != excludingRef else { continue }
            rows[hit.id] = hit; rank[hit.id, default: 0] += 1 / Double(60 + i)
        }

        // 2. Meaning (vectors), compared against every chunk in scope.
        if let q = embedder?.embed(query) {
            var scored: [(Int64, Float)] = []
            let vsql = "SELECT c.id, c.scope, c.source, c.ref, c.text, c.vec FROM chunks c WHERE c.vec IS NOT NULL\(scopeSQL)"
            for r in fetch(vsql, scopeArgs) {
                guard let h = hit(from: r), h.ref != excludingRef, case .blob(let d) = r[5], d.count == q.count * 4 else { continue }
                let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var dot: Float = 0
                for i in 0..<q.count { dot += q[i] * v[i] }
                if dot > 0.45 { scored.append((h.id, dot)); rows[h.id] = h }      // ignore weak, unrelated matches
            }
            for (i, s) in scored.sorted(by: { $0.1 > $1.1 }).prefix(20).enumerated() { rank[s.0, default: 0] += 1 / Double(60 + i) }
        }

        return rank.sorted { $0.value > $1.value }.prefix(limit).compactMap { id, score in rows[id].map { var h = $0; h.score = score; return h } }
    }

    // MARK: SQLite plumbing

    enum Value { case text(String), double(Double), blob(Data), null }

    private func hit(from r: [Value]) -> Hit? {
        guard case .text(let scope) = r[1], case .text(let source) = r[2], case .text(let ref) = r[3], case .text(let text) = r[4], case .double(let id) = r[0] else { return nil }
        return Hit(id: Int64(id), scope: scope, source: source, ref: ref, text: text, score: 0)
    }

    private func exec(_ sql: String) { guard let db else { return }; sqlite3_exec(db, sql, nil, nil, nil) }

    private func prepare(_ sql: String, _ args: [Value]) -> OpaquePointer? {
        guard let db else { return nil }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(st, n, s, -1, Self.transient)
            case .double(let d): sqlite3_bind_double(st, n, d)
            case .blob(let d): d.withUnsafeBytes { _ = sqlite3_bind_blob(st, n, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null: sqlite3_bind_null(st, n)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: [Value]) {
        guard let st = prepare(sql, args) else { return }
        sqlite3_step(st); sqlite3_finalize(st)
    }

    private func scalar(_ sql: String, _ args: [Value]) -> Double? {
        guard let st = prepare(sql, args) else { return nil }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_double(st, 0) : nil
    }

    /// Every row as an array of values. The first column of an id is returned as a double to keep one value type.
    private func fetch(_ sql: String, _ args: [Value]) -> [[Value]] {
        guard let st = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [[Value]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [Value] = []
            for c in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER, SQLITE_FLOAT: row.append(.double(sqlite3_column_double(st, c)))
                case SQLITE_BLOB: row.append(.blob(Data(bytes: sqlite3_column_blob(st, c), count: Int(sqlite3_column_bytes(st, c)))))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(st, c))))
                default: row.append(.null)
                }
            }
            out.append(row)
        }
        return out
    }
}

/// What a session recalls at the start: the best matches for its first message, written as short bullet points.
public enum Recall {
    public static func context(_ hits: [MemoryIndex.Hit], titles: [String: String] = [:], limit: Int = 1500) -> String? {
        guard !hits.isEmpty else { return nil }
        var out = "Possibly relevant earlier context from the user's CPilot memory. It may be out of date, so check before relying on it:\n"
        var n = 0
        for h in hits {
            let label = h.source == "note" ? "note \"\(h.ref)\"" : "earlier session \"\(titles[h.ref] ?? "untitled")\""
            let line = "- (\(label)) \(ContextDigest.compact(h.text, limit: 300))\n"
            if out.count + line.count > limit { break }
            out += line; n += 1
        }
        return n == 0 ? nil : out
    }
}
