// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
import Darwin

/// One saved state of a note: who wrote it, why, when, and the full text, so any version can be read or brought back.
public struct MemoryVersion: Codable, Identifiable, Equatable, Sendable {
    /// 1, 2, 3 … per note, never reused.
    public var id: Int
    public var date: Date
    /// "you", "lessons", "agent", "dream", "restore", or "outside edit" for a change made to the file without CPilot.
    public var actor: String
    public var reason: String
    public var hash: String
    public var body: String
    /// The note was deleted at this point; `body` is empty.
    public var deleted: Bool
}

/// What a writer says about the note it is about to replace.
public enum MemoryExpect: Equatable, Sendable {
    /// Replace whatever is there. The old text stays in the history.
    case anything
    /// The note must not exist yet.
    case absent
    /// The note must still have the text the writer read, identified by `MemoryStore.hash`.
    case hash(String)
}

public enum MemoryWrite: Equatable, Sendable {
    case saved(MemoryNote)
    /// The note is not what the writer expected: someone changed, created or deleted it since it was read. `current` is what is there now (nil when it is gone); read it, merge, and try again.
    case conflict(current: MemoryNote?)
    /// An automated writer's text broke the memory rules (see `MemoryLint`); nothing was written. The reasons are for the writer to fix.
    case rejected([String])
    /// The file could not be written.
    case failed
}

/// Several writers use one memory at once: the app, the lessons pass, agents through the MCP server (a separate process) and you. Every change goes through `write`, which holds a lock
/// shared by all processes, checks that the note is still the one the writer read, and records a version. Nothing a writer replaces is lost.
extension MemoryStore {
    /// Versions kept per note; the oldest go first.
    public static let versionLimit = 100
    public static let reasonLimit = 200

    public static func hash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var historyRoot: URL { root.appendingPathComponent(".history", isDirectory: true) }
    private func historyURL(_ scope: String, _ name: String) -> URL { historyRoot.appendingPathComponent(scope, isDirectory: true).appendingPathComponent(name + ".jsonl") }

    /// Runs `body` while holding the memory lock, which other processes honour too.
    func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    func note(scope: String, name: String) -> MemoryNote? {
        let u = dir(scope).appendingPathComponent(name + ".md")
        guard let body = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        return MemoryNote(scope: scope, name: name, body: body, modified: date)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func versions(scope: String, name: String) -> [MemoryVersion] {
        guard let text = try? String(contentsOf: historyURL(scope, name), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { try? Self.decoder.decode(MemoryVersion.self, from: Data($0.utf8)) }
    }

    /// Adds a version. Must be called with the lock held.
    func append(scope: String, name: String, actor: String, reason: String, body: String, deleted: Bool = false) {
        var all = versions(scope: scope, name: name)
        let v = MemoryVersion(id: (all.last?.id ?? 0) + 1, date: .now, actor: actor, reason: String(reason.prefix(Self.reasonLimit)), hash: Self.hash(body), body: body, deleted: deleted)
        all.append(v)
        let url = historyURL(scope, name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = all.suffix(Self.versionLimit).compactMap { try? Self.encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A file changed or removed without CPilot (an editor, an agent with file access) is recorded as its own version before anything replaces it. Must be called with the lock held.
    func adoptOutsideEdit(scope: String, name: String, current: MemoryNote?) {
        let latest = versions(scope: scope, name: name).last
        if let current {
            if latest == nil || latest!.deleted || latest!.hash != current.hash {
                append(scope: scope, name: name, actor: "outside edit", reason: "Changed outside CPilot; kept here", body: current.body)
            }
        } else if let latest, !latest.deleted {
            append(scope: scope, name: name, actor: "outside edit", reason: "Removed outside CPilot", body: "", deleted: true)
        }
    }

    /// Replaces a note, if it is still what the writer expects, and records the version.
    public func write(scope: String, name: String, body: String, expect: MemoryExpect = .anything, actor: String, reason: String = "") -> MemoryWrite {
        let safe = Self.safeName(name)
        return withLock { writeLocked(scope: scope, name: safe, body: body, expect: expect, actor: actor, reason: reason) }
    }

    /// Changes a note from what it holds right now: `change` gets the current text (nil when there is no note) and returns the new text, or nil to leave it alone. The read, the change and the
    /// write happen under the lock, so concurrent updates each build on the last one and none is lost. Returns the saved note, or nil when nothing was written.
    @discardableResult
    public func update(scope: String, name: String, actor: String, reason: String = "", _ change: (String?) -> String?) -> MemoryNote? {
        let safe = Self.safeName(name)
        return withLock {
            let current = note(scope: scope, name: safe)
            adoptOutsideEdit(scope: scope, name: safe, current: current)
            guard let body = change(current?.body) else { return nil }
            if case .saved(let n) = writeLocked(scope: scope, name: safe, body: body, expect: .anything, actor: actor, reason: reason) { return n }
            return nil
        }
    }

    /// The body of `write`, with the lock already held and `name` already made safe.
    private func writeLocked(scope: String, name safe: String, body: String, expect: MemoryExpect, actor: String, reason: String) -> MemoryWrite {
        let current = note(scope: scope, name: safe)
        adoptOutsideEdit(scope: scope, name: safe, current: current)
        switch expect {
        case .anything: break
        case .absent: if current != nil { return .conflict(current: current) }
        case .hash(let h): if current?.hash != h { return .conflict(current: current) }
        }
        if let current, current.body == body { return .saved(current) }
        if !MemoryLint.isPerson(actor) {
            var why = MemoryLint.problems(body)
            if MemoryLint.wipes(old: current?.body, new: body) { why.append("replaces most of the note") }
            if !why.isEmpty { return .rejected(why) }
        }
        let d = dir(scope)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard (try? body.write(to: d.appendingPathComponent(safe + ".md"), atomically: true, encoding: .utf8)) != nil else { return .failed }
        append(scope: scope, name: safe, actor: actor, reason: reason, body: body)
        index?.replace(scope: scope, source: "note", ref: safe, text: safe + "\n\n" + body)
        return .saved(MemoryNote(scope: scope, name: safe, body: body, modified: .now))
    }

    /// Saves a new note without replacing one that has the same name: the name gets " 2", " 3" … until it is free.
    @discardableResult
    public func create(scope: String, name: String, body: String, actor: String, reason: String = "") -> MemoryNote? {
        for n in 1...50 {
            let candidate = n == 1 ? name : "\(name) \(n)"
            switch write(scope: scope, name: candidate, body: body, expect: .absent, actor: actor, reason: reason) {
            case .saved(let note): return note
            case .conflict: continue
            case .failed, .rejected: return nil
            }
        }
        return nil
    }

    /// Every recorded version of a note, newest first.
    public func history(scope: String, name: String) -> [MemoryVersion] {
        let safe = Self.safeName(name)
        return withLock {
            adoptOutsideEdit(scope: scope, name: safe, current: note(scope: scope, name: safe))
            return versions(scope: scope, name: safe).reversed()
        }
    }

    /// Brings an earlier version back as a new version; the history is never rewritten. Works for a deleted note too.
    public func restore(scope: String, name: String, version: Int, actor: String = "you") -> MemoryWrite {
        guard let v = history(scope: scope, name: name).first(where: { $0.id == version }), !v.deleted else { return .failed }
        return write(scope: scope, name: name, body: v.body, actor: actor, reason: "Restored version \(version)")
    }

    /// Every deleted note that can be restored, in any scope.
    public func allDeletedNotes() -> [(scope: String, name: String)] {
        let scopes = ((try? FileManager.default.contentsOfDirectory(atPath: historyRoot.path)) ?? []).sorted()
        return scopes.flatMap { sc in deletedNotes(scope: sc).map { (scope: sc, name: $0) } }
    }

    /// Notes in a scope that were deleted and can be restored.
    public func deletedNotes(scope: String) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: historyRoot.appendingPathComponent(scope).path)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }
        return withLock { names.filter { n in note(scope: scope, name: n) == nil && versions(scope: scope, name: n).last?.deleted == true }.sorted() }
    }
}
