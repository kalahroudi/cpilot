// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A pull request with the state of its checks, read in one request for the whole repository.
public struct CIPullRequest: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public var name: String?          // a check run
        public var context: String?       // a commit status
        public var status: String?        // QUEUED, IN_PROGRESS, COMPLETED
        public var conclusion: String?
        public var state: String?         // commit status: SUCCESS, PENDING, FAILURE, ERROR
        public init(name: String? = nil, context: String? = nil, status: String? = nil, conclusion: String? = nil, state: String? = nil) {
            self.name = name; self.context = context; self.status = status; self.conclusion = conclusion; self.state = state
        }
    }
    public var number: Int
    public var title: String
    public var url: String
    public var headRefOid: String
    public var statusCheckRollup: [Item]?
    /// MERGEABLE, CONFLICTING, or UNKNOWN while GitHub is still working it out.
    public var mergeable: String?
    public init(number: Int, title: String, url: String, headRefOid: String, statusCheckRollup: [Item]?, mergeable: String? = nil) {
        self.number = number; self.title = title; self.url = url; self.headRefOid = headRefOid; self.statusCheckRollup = statusCheckRollup; self.mergeable = mergeable
    }
    public static let fields = "number,title,url,headRefOid,statusCheckRollup,mergeable"
}

public enum CIVerdict: Equatable, Sendable {
    case none, pending, passed
    case failed([String])

    /// A failure counts as soon as one check fails, even while others still run: that is when you want to know.
    public static func of(_ items: [CIPullRequest.Item]?) -> CIVerdict {
        guard let items, !items.isEmpty else { return .none }
        var failed: [String] = [], pending = false
        for i in items {
            let name = i.name ?? i.context ?? "check"
            if let state = i.state?.uppercased() {
                switch state {
                case "SUCCESS": break
                case "FAILURE", "ERROR": failed.append(name)
                default: pending = true
                }
            } else if i.status?.uppercased() != "COMPLETED" {
                pending = true
            } else {
                switch (i.conclusion ?? "").uppercased() {
                case "SUCCESS", "NEUTRAL", "SKIPPED": break
                default: failed.append(name)
                }
            }
        }
        if !failed.isEmpty { return .failed(failed) }
        return pending ? .pending : .passed
    }
    var isFinal: Bool { switch self { case .passed, .failed: return true; default: return false } }
}

/// Remembers what each pull request's checks looked like and reports only the moment they finish, once per commit,
/// and the moment a pull request starts to conflict with its base.
public struct CIWatch: Sendable {
    public struct Event: Equatable, Sendable {
        public var pr: CIPullRequest; public var verdict: CIVerdict
        /// True when this event is "the pull request now conflicts", not about its checks.
        public var conflict = false
        public init(pr: CIPullRequest, verdict: CIVerdict, conflict: Bool = false) { self.pr = pr; self.verdict = verdict; self.conflict = conflict }
    }
    private var seen: [String: (oid: String, verdict: CIVerdict)] = [:]
    private var conflicting: Set<String> = []
    public private(set) var hasPending = false
    public init() {}

    public mutating func observe(_ prs: [CIPullRequest]) -> [Event] {
        var events: [Event] = [], now: [String: (oid: String, verdict: CIVerdict)] = [:]
        hasPending = false
        var stillConflicting: Set<String> = []
        for pr in prs {
            let v = CIVerdict.of(pr.statusCheckRollup)
            now[pr.url] = (pr.headRefOid, v)
            if v == .pending || pr.mergeable == "UNKNOWN" { hasPending = true }
            if pr.mergeable == "CONFLICTING" {
                stillConflicting.insert(pr.url)
                if !conflicting.contains(pr.url) { events.append(Event(pr: pr, verdict: v, conflict: true)) }
            }
            guard v.isFinal, let before = seen[pr.url] else { continue }
            // Seen running, or a new commit that has already finished between two looks. A PR first met finished is not news.
            if before.oid != pr.headRefOid || before.verdict == .pending { events.append(Event(pr: pr, verdict: v)) }
        }
        seen = now; conflicting = stillConflicting
        return events
    }
}

extension GitHub {
    /// The signed-in user's open pull requests with their checks: one request per repository, however many pull requests there are.
    public static func mineWithChecks(in dir: String) async throws -> [CIPullRequest] {
        let out = try await Shell.check("gh", ["pr", "list", "--author", "@me", "--state", "open", "--limit", "30", "--json", CIPullRequest.fields], cwd: url(dir))
        return try JSONDecoder().decode([CIPullRequest].self, from: Data(out.utf8))
    }
}
