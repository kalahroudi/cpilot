// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// One model call as Claude Code recorded it in a transcript: what it read, wrote and produced.
public struct UsageRow: Equatable, Sendable {
    public var session: String
    public var id: String
    public var model: String
    public var ts: Date
    public var cwd: String
    public var input: Int
    public var cacheRead: Int
    public var write5m: Int
    public var write1h: Int
    public var output: Int
    /// A call made by a sub-agent: it has a context of its own, apart from the conversation's.
    public var sidechain: Bool

    public init(session: String, id: String, model: String = "", ts: Date = .distantPast, cwd: String = "", input: Int = 0, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0, output: Int = 0, sidechain: Bool = false) {
        self.session = session; self.id = id; self.model = model; self.ts = ts; self.cwd = cwd; self.input = input; self.cacheRead = cacheRead
        self.write5m = write5m; self.write1h = write1h; self.output = output; self.sidechain = sidechain
    }

    public var cacheWrite: Int { write5m + write1h }
    /// Everything the model was given for this call.
    public var context: Int { input + cacheRead + cacheWrite }
}

/// A tool call and how large its result was, in characters (what went back into the conversation).
public struct ToolEvent: Equatable, Sendable {
    public var useId: String
    public var session: String
    public var name: String
    public var ts: Date
    public var resultChars: Int?
}

/// Dollars per million tokens. Max plans are not billed per token, so this is what the same use would cost on the API, to compare sessions and changes.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Writing to the cache costs 1.25x the input price for 5 minutes and 2x for an hour.
    public var write5m: Double { input * 1.25 }
    public var write1h: Double { input * 2 }

    /// Longest prefix first. Haiku 5.5's cache read is assumed to be a tenth of its input price (the others are as published).
    static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5", ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]

    public static func forModel(_ model: String) -> ModelPrice? {
        table.filter { model.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
    }

    public func cost(of r: UsageRow) -> Double {
        (Double(r.input) * input + Double(r.output) * output + Double(r.cacheRead) * cacheRead + Double(r.write5m) * write5m + Double(r.write1h) * write1h) / 1_000_000
    }
}

/// Reads Claude Code transcripts (one JSON object per line). The format is Claude Code's, not a contract, so anything unexpected is skipped, never guessed.
public enum TranscriptUsage {
    public struct Parsed: Equatable, Sendable {
        public var rows: [UsageRow] = []
        public var tools: [ToolEvent] = []
    }

    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plainDates = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return dates.date(from: s) ?? plainDates.date(from: s) ?? .distantPast
    }

    /// Claude Code writes one line per content block of a message, each carrying the same message id and usage (the output count grows as the message streams).
    /// So rows are merged by id: counted once, with the largest output seen.
    public static func parse(_ text: String, session fallback: String) -> Parsed { parse(Data(text.utf8), session: fallback) }

    private static let usageMark = Data("\"usage\"".utf8)
    private static let resultMark = Data("\"tool_result\"".utf8)

    /// Most lines of a transcript (request blobs, attachments, snapshots) are large and say nothing about usage, so a line is decoded only when it can.
    public static func parse(_ data: Data, session fallback: String) -> Parsed {
        var order: [String] = []
        var rows: [String: UsageRow] = [:]
        var tools: [String: ToolEvent] = [:]
        var toolOrder: [String] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.first == 0x7B, line.range(of: usageMark) != nil || line.range(of: resultMark) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String, let message = obj["message"] as? [String: Any] else { continue }
            let session = (obj["sessionId"] as? String) ?? fallback
            let ts = date(obj["timestamp"] as? String)
            if type == "assistant" {
                if let id = message["id"] as? String, let u = message["usage"] as? [String: Any] {
                    let total5m1h = u["cache_creation_input_tokens"] as? Int ?? 0
                    let oneHour = (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
                    var r = UsageRow(session: session, id: id, model: message["model"] as? String ?? "", ts: ts, cwd: obj["cwd"] as? String ?? "",
                                     input: u["input_tokens"] as? Int ?? 0, cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                     write5m: max(0, total5m1h - oneHour), write1h: min(oneHour, total5m1h), output: u["output_tokens"] as? Int ?? 0,
                                     sidechain: obj["isSidechain"] as? Bool ?? false)
                    if let old = rows[id] { r.output = max(r.output, old.output); if r.cwd.isEmpty { r.cwd = old.cwd }; r.ts = min(r.ts, old.ts) } else { order.append(id) }
                    rows[id] = r
                }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    if tools[id] == nil { toolOrder.append(id); tools[id] = ToolEvent(useId: id, session: session, name: name, ts: ts, resultChars: nil) }
                }
            } else if type == "user" {
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let size = chars(block["content"])
                    if var t = tools[id] { t.resultChars = size; tools[id] = t }
                    else { toolOrder.append(id); tools[id] = ToolEvent(useId: id, session: session, name: "", ts: ts, resultChars: size) }
                }
            }
        }
        return Parsed(rows: order.compactMap { rows[$0] }, tools: toolOrder.compactMap { tools[$0] })
    }

    /// The size of a tool result: a string, or a list of text blocks. Images count as their encoded length, which is what the model is charged for roughly.
    static func chars(_ content: Any?) -> Int {
        if let s = content as? String { return s.count }
        if let list = content as? [[String: Any]] {
            return list.reduce(0) { sum, b in
                if let t = b["text"] as? String { return sum + t.count }
                if let src = b["source"] as? [String: Any], let d = src["data"] as? String { return sum + d.count }
                return sum
            }
        }
        return 0
    }
}

/// What a session has used, added up.
public struct SessionUsage: Equatable, Sendable {
    public var session: String
    public var cwd: String
    public var model: String
    public var calls: Int
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int
    /// The largest and the latest context the conversation itself (not a sub-agent) was given.
    public var peakContext: Int
    public var lastContext: Int
    public var cost: Double?
    public var first: Date
    public var last: Date
    /// Pauses longer than the cache lives (see `cacheLife`) before a call, and what that call then had to write again.
    public var coldStarts: Int
    public var rewrittenAfterGaps: Int
    /// How long this session's cache lives: an hour when most of what it wrote used the one-hour cache (Claude Code's usual), otherwise five minutes.
    public var cacheLife: TimeInterval = UsageMetrics.shortCacheLife

    /// Share of what was sent that came from the cache. Writes count as billed input, as in `claude-stat`.
    public var cacheHitRate: Double? { UsageMetrics.hitRate(read: cacheRead, write: cacheWrite, input: input) }
}

public enum UsageMetrics {
    public static let shortCacheLife: TimeInterval = 300
    public static let longCacheLife: TimeInterval = 3600

    /// Read from what the session wrote: the one-hour cache when at least half of the written tokens were of that kind.
    public static func cacheLife(of rows: [UsageRow]) -> TimeInterval {
        let long = rows.reduce(0) { $0 + $1.write1h }, short = rows.reduce(0) { $0 + $1.write5m }
        return long > 0 && long >= short ? longCacheLife : shortCacheLife
    }

    public static func hitRate(read: Int, write: Int, input: Int) -> Double? {
        let total = read + write + input
        return total > 0 ? Double(read) / Double(total) : nil
    }

    public static func summarize(_ rows: [UsageRow]) -> SessionUsage? {
        guard let firstRow = rows.min(by: { $0.ts < $1.ts }) else { return nil }
        let ordered = rows.sorted { $0.ts < $1.ts }
        var cost: Double? = 0
        for r in ordered {
            if let p = ModelPrice.forModel(r.model) { cost = (cost ?? 0) + p.cost(of: r) } else if r.context + r.output > 0 { cost = nil; break }
        }
        let main = ordered.filter { !$0.sidechain }
        var cold = 0, rewritten = 0
        let life = cacheLife(of: rows)
        for (a, b) in zip(main, main.dropFirst()) where b.ts.timeIntervalSince(a.ts) > life { cold += 1; rewritten += b.cacheWrite }
        // The model shown is the one that made the latest call.
        let latest = ordered.last { !$0.model.isEmpty && !$0.model.hasPrefix("<") }
        return SessionUsage(session: firstRow.session, cwd: ordered.first { !$0.cwd.isEmpty }?.cwd ?? "", model: latest?.model ?? "", calls: rows.count,
                            input: rows.reduce(0) { $0 + $1.input }, cacheRead: rows.reduce(0) { $0 + $1.cacheRead }, cacheWrite: rows.reduce(0) { $0 + $1.cacheWrite },
                            output: rows.reduce(0) { $0 + $1.output }, peakContext: main.map(\.context).max() ?? 0, lastContext: main.last?.context ?? 0,
                            cost: cost, first: firstRow.ts, last: ordered.last?.ts ?? firstRow.ts, coldStarts: cold, rewrittenAfterGaps: rewritten, cacheLife: life)
    }

    /// The tools whose results were largest, summed per tool name. Roughly four characters make a token.
    public static func biggestResults(_ tools: [ToolEvent], limit: Int = 5) -> [(name: String, calls: Int, chars: Int)] {
        var by: [String: (Int, Int)] = [:]
        for t in tools { guard let c = t.resultChars else { continue }; let n = t.name.isEmpty ? "(unknown)" : t.name; let o = by[n] ?? (0, 0); by[n] = (o.0 + 1, o.1 + c) }
        return by.map { (name: $0.key, calls: $0.value.0, chars: $0.value.1) }.sorted { $0.chars > $1.chars }.prefix(limit).map { $0 }
    }

    /// Context above which a session is worth forking, and the context a window holds (all current models: 1M).
    public static let forkThreshold = 200_000
}

/// The usage ledger: every model call found in Claude Code's transcripts, in one SQLite file next to the memory index. Thread safe.
/// It stores sizes and names, never what was said.
public final class UsageStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL = AppPaths().root.appendingPathComponent("usage.db")) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS usage(session TEXT NOT NULL, id TEXT NOT NULL, model TEXT, ts REAL, cwd TEXT, input INT, read INT, w5 INT, w1 INT, out INT, side INT, PRIMARY KEY(session, id))")
        exec("CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts)")
        exec("CREATE TABLE IF NOT EXISTS tools(use_id TEXT PRIMARY KEY, session TEXT, name TEXT, ts REAL, chars INT)")
        exec("CREATE INDEX IF NOT EXISTS tools_session ON tools(session)")
        exec("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, off INT, size INT)")
    }

    deinit { if let db { sqlite3_close(db) } }

    public var isOpen: Bool { db != nil }

    @discardableResult private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        bind(st); sqlite3_step(st); sqlite3_finalize(st)
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }

    /// Adds what a transcript chunk held. A message seen again keeps its largest output; a tool result that arrives after its call fills it in.
    public func add(_ p: TranscriptUsage.Parsed) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        exec("BEGIN")
        for r in p.rows {
            run("""
                INSERT INTO usage(session,id,model,ts,cwd,input,read,w5,w1,out,side) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(session,id) DO UPDATE SET model=excluded.model, ts=min(ts,excluded.ts), cwd=CASE WHEN excluded.cwd='' THEN cwd ELSE excluded.cwd END,
                input=excluded.input, read=excluded.read, w5=excluded.w5, w1=excluded.w1, out=max(out,excluded.out), side=excluded.side
                """) { st in
                sqlite3_bind_text(st, 1, r.session, -1, Self.transient); sqlite3_bind_text(st, 2, r.id, -1, Self.transient); sqlite3_bind_text(st, 3, r.model, -1, Self.transient)
                sqlite3_bind_double(st, 4, r.ts.timeIntervalSince1970); sqlite3_bind_text(st, 5, r.cwd, -1, Self.transient)
                sqlite3_bind_int64(st, 6, Int64(r.input)); sqlite3_bind_int64(st, 7, Int64(r.cacheRead)); sqlite3_bind_int64(st, 8, Int64(r.write5m))
                sqlite3_bind_int64(st, 9, Int64(r.write1h)); sqlite3_bind_int64(st, 10, Int64(r.output)); sqlite3_bind_int(st, 11, r.sidechain ? 1 : 0)
            }
        }
        for t in p.tools {
            run("""
                INSERT INTO tools(use_id,session,name,ts,chars) VALUES(?,?,?,?,?)
                ON CONFLICT(use_id) DO UPDATE SET name=CASE WHEN excluded.name='' THEN name ELSE excluded.name END, chars=COALESCE(excluded.chars, chars),
                ts=CASE WHEN excluded.name='' THEN ts ELSE excluded.ts END
                """) { st in
                sqlite3_bind_text(st, 1, t.useId, -1, Self.transient); sqlite3_bind_text(st, 2, t.session, -1, Self.transient); sqlite3_bind_text(st, 3, t.name, -1, Self.transient)
                sqlite3_bind_double(st, 4, t.ts.timeIntervalSince1970)
                if let c = t.resultChars { sqlite3_bind_int64(st, 5, Int64(c)) } else { sqlite3_bind_null(st, 5) }
            }
        }
        exec("COMMIT")
    }

    public func rows(session: String? = nil, since: Date = .distantPast) -> [UsageRow] {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return [] }
        var st: OpaquePointer?
        let sql = "SELECT session,id,model,ts,cwd,input,read,w5,w1,out,side FROM usage WHERE ts >= ?" + (session == nil ? "" : " AND session = ?") + " ORDER BY ts"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, since == .distantPast ? 0 : since.timeIntervalSince1970)
        if let session { sqlite3_bind_text(st, 2, session, -1, Self.transient) }
        var out: [UsageRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(UsageRow(session: text(st, 0), id: text(st, 1), model: text(st, 2), ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)), cwd: text(st, 4),
                                input: Int(sqlite3_column_int64(st, 5)), cacheRead: Int(sqlite3_column_int64(st, 6)), write5m: Int(sqlite3_column_int64(st, 7)),
                                write1h: Int(sqlite3_column_int64(st, 8)), output: Int(sqlite3_column_int64(st, 9)), sidechain: sqlite3_column_int(st, 10) != 0))
        }
        return out
    }

    public func tools(session: String) -> [ToolEvent] {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT use_id,session,name,ts,chars FROM tools WHERE session = ? ORDER BY ts", -1, &st, nil) == SQLITE_OK, let st else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, session, -1, Self.transient)
        var out: [ToolEvent] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(ToolEvent(useId: text(st, 0), session: text(st, 1), name: text(st, 2), ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                                 resultChars: sqlite3_column_type(st, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 4))))
        }
        return out
    }

    /// One summary per session, newest first.
    public func sessions(since: Date = .distantPast) -> [SessionUsage] {
        Dictionary(grouping: rows(since: since), by: \.session).compactMap { UsageMetrics.summarize($0.value) }.sorted { $0.last > $1.last }
    }

    public func summary(session: String) -> SessionUsage? { UsageMetrics.summarize(rows(session: session)) }

    // MARK: Incremental import

    func offset(of path: String) -> (off: Int, size: Int) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard db != nil, sqlite3_prepare_v2(db, "SELECT off,size FROM files WHERE path = ?", -1, &st, nil) == SQLITE_OK, let st else { return (0, 0) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, path, -1, Self.transient)
        return sqlite3_step(st) == SQLITE_ROW ? (Int(sqlite3_column_int64(st, 0)), Int(sqlite3_column_int64(st, 1))) : (0, 0)
    }

    func setOffset(_ off: Int, size: Int, of path: String) {
        lock.lock(); defer { lock.unlock() }
        run("INSERT INTO files(path,off,size) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET off=excluded.off, size=excluded.size") { st in
            sqlite3_bind_text(st, 1, path, -1, Self.transient); sqlite3_bind_int64(st, 2, Int64(off)); sqlite3_bind_int64(st, 3, Int64(size))
        }
    }

    /// Reads what each transcript under `root` gained since the last time, so a launch reads only what is new. A transcript that shrank was rewritten and is read again from the start.
    /// A transcript never read before and untouched for `maxAge` is left out, and the newest are read first, so the recent weeks are there within moments of the first launch.
    /// Returns how many files held something new.
    @discardableResult
    public func sync(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true), maxAge: TimeInterval = 90 * 86_400) -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return 0 }
        var found: [(url: URL, size: Int, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = v.fileSize else { continue }
            found.append((url, size, v.contentModificationDate ?? .distantPast))
        }
        var changed = 0
        for f in found.sorted(by: { $0.modified > $1.modified }) {
            var (off, known) = offset(of: f.url.path)
            if known == 0, Date().timeIntervalSince(f.modified) > maxAge { continue }
            if f.size < known || off > f.size { off = 0 }
            if f.size == off { continue }
            guard let h = try? FileHandle(forReadingFrom: f.url) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: UInt64(off))
            guard let data = try? h.readToEnd(), let end = data.lastIndex(of: 0x0A) else { continue }
            let chunk = data.prefix(through: end)
            add(TranscriptUsage.parse(Data(chunk), session: f.url.deletingPathExtension().lastPathComponent))
            setOffset(off + chunk.count, size: f.size, of: f.url.path)
            known = f.size; changed += 1
        }
        return changed
    }
}
