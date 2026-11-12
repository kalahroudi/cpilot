// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// A decision CPilot puts to a person, written so it can be understood at a glance: what is proposed, why it matters, what CPilot recommends, and what each answer does.
/// Dreams use it for memory changes; spec, test and merge checkpoints use the same card.
public struct Proposal: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Waiting for a person.
        case open
        /// A person said yes and the change is waiting to be made by the owner of its kind.
        case approved
        /// A person said no.
        case declined
        /// The change was made (by a person's yes, or automatically when the rules allow).
        case applied
        /// The change was made and then taken back.
        case undone
        /// The thing it would change moved on since it was proposed, so it was not made.
        case stale
    }

    public var id: String
    /// Who acts on it: "dream", and later "spec", "policy" and "merge".
    public var kind: String
    /// What it belongs to: a memory scope or a repository.
    public var scope: String
    /// One sentence: what is proposed.
    public var what: String
    /// One sentence: the consequence of leaving it, or of getting it wrong.
    public var why: String
    public var recommendation: String
    public var ifApprove: String
    public var ifDecline: String
    /// Short lines a person can read to check it: a quote, a spec line, a failing test. Shown collapsed.
    public var evidence: [String]
    /// What the owner of the kind needs to act on it, as JSON.
    public var payload: String
    public var created: Date
    public var status: Status
    /// "you", or "auto" when the rules let CPilot decide.
    public var decidedBy: String?
    public var decidedAt: Date?
    /// Why it ended as it did, when that is not obvious ("changed since it was proposed").
    public var outcome: String?

    public init(id: String = UUID().uuidString, kind: String, scope: String, what: String, why: String, recommendation: String, ifApprove: String, ifDecline: String,
                evidence: [String] = [], payload: String = "", created: Date = .now, status: Status = .open) {
        self.id = id; self.kind = kind; self.scope = scope; self.what = what; self.why = why; self.recommendation = recommendation
        self.ifApprove = ifApprove; self.ifDecline = ifDecline; self.evidence = evidence; self.payload = payload; self.created = created; self.status = status
    }

    public var isOpen: Bool { status == .open }
}

/// Proposals kept in one JSON file. Every change is read-modify-write under a file lock, so the app and the MCP server (separate processes) can both use it.
public final class ProposalStore: @unchecked Sendable {
    public let file: URL
    /// Decided proposals kept for the history; open ones are never dropped.
    public static let keepDecided = 200

    public init(file: URL = AppPaths().proposalsFile) { self.file = file }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    private func read() -> [Proposal] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([Proposal].self, from: data)) ?? []
    }

    private func write(_ all: [Proposal]) {
        let open = all.filter(\.isOpen), decided = all.filter { !$0.isOpen }.suffix(Self.keepDecided)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(open + decided) { try? data.write(to: file, options: .atomic) }
    }

    /// Everything, oldest first.
    public func all() -> [Proposal] { locked { read().sorted { $0.created < $1.created } } }

    public func open(kind: String? = nil, scope: String? = nil) -> [Proposal] {
        all().filter { $0.isOpen && (kind == nil || $0.kind == kind) && (scope == nil || $0.scope == scope) }
    }

    public func proposal(_ id: String) -> Proposal? { all().first { $0.id == id } }

    public func add(_ p: Proposal) {
        locked {
            var all = read().filter { $0.id != p.id }
            all.append(p); write(all)
        }
    }

    /// Changes one proposal under the lock. Returns the result, or nil when there is no such proposal or `change` returned false.
    @discardableResult
    public func update(_ id: String, _ change: (inout Proposal) -> Bool) -> Proposal? {
        locked {
            var all = read()
            guard let i = all.firstIndex(where: { $0.id == id }), change(&all[i]) else { return nil }
            write(all)
            return all[i]
        }
    }

    /// Records a decision on an open proposal. A proposal that was already decided is left alone, so two answers cannot fight.
    @discardableResult
    public func decide(_ id: String, _ status: Proposal.Status, by who: String, outcome: String? = nil) -> Proposal? {
        update(id) { p in
            guard p.isOpen else { return false }
            p.status = status; p.decidedBy = who; p.decidedAt = .now; p.outcome = outcome
            return true
        }
    }
}
