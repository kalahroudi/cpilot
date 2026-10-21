// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct PullRequest: Codable, Identifiable, Equatable, Sendable {
    public struct Author: Codable, Equatable, Sendable { public var login: String; public init(login: String) { self.login = login } }
    public struct Check: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var state: String          // SUCCESS, FAILURE, PENDING, ...
        public var link: String?
        public var id: String { name }
        public init(name: String, state: String, link: String? = nil) { self.name = name; self.state = state; self.link = link }
        public var passed: Bool { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(state.uppercased()) }
        public var failed: Bool { ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT"].contains(state.uppercased()) }
    }
    public var number: Int
    public var title: String
    public var state: String                    // OPEN, MERGED, CLOSED
    public var isDraft: Bool
    public var headRefName: String
    public var baseRefName: String
    public var author: Author?
    public var url: String
    public var body: String?
    public var additions: Int?
    public var deletions: Int?
    public var reviewDecision: String?
    public var mergeable: String?
    public var autoMergeRequest: AutoMerge?
    public struct AutoMerge: Codable, Equatable, Sendable { public var mergeMethod: String?; public init(mergeMethod: String?) { self.mergeMethod = mergeMethod } }
    public init(number: Int, title: String, state: String, isDraft: Bool, headRefName: String, baseRefName: String, author: Author?, url: String,
                body: String? = nil, additions: Int? = nil, deletions: Int? = nil, reviewDecision: String? = nil, mergeable: String? = nil,
                autoMergeRequest: AutoMerge? = nil) {
        self.number = number; self.title = title; self.state = state; self.isDraft = isDraft; self.headRefName = headRefName
        self.baseRefName = baseRefName; self.author = author; self.url = url; self.body = body; self.additions = additions
        self.deletions = deletions; self.reviewDecision = reviewDecision; self.mergeable = mergeable; self.autoMergeRequest = autoMergeRequest
    }
    public var id: Int { number }
    public var isOpen: Bool { state == "OPEN" }
    public var autoMerge: Bool { autoMergeRequest != nil }

    public static let listFields = "number,title,state,isDraft,headRefName,baseRefName,author,url,autoMergeRequest,reviewDecision"
    public static let viewFields = listFields + ",body,additions,deletions,mergeable"
}

public enum MergeMethod: String, CaseIterable, Sendable { case squash, merge, rebase }
public enum ReviewAction: String, Sendable { case approve, requestChanges = "request-changes", comment }

/// Everything about GitHub goes through the user's own `gh`, so there is no second login and no token stored by CPilot.
public enum GitHub {
    static func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    public struct Account: Equatable, Sendable { public var login: String; public var scopes: String; public init(login: String, scopes: String) { self.login = login; self.scopes = scopes } }

    public static func account() async -> Account? {
        guard let r = try? await Shell.run("gh", ["auth", "status", "--active"]), r.ok || r.stdout.contains("Logged in") else { return nil }
        let out = r.stdout + r.stderr
        var login = ""
        if let range = out.range(of: "account ") { login = String(out[range.upperBound...].prefix { !$0.isWhitespace }) }
        if login.isEmpty, let u = try? await Shell.check("gh", ["api", "user", "--jq", ".login"]) { login = u.trimmingCharacters(in: .whitespacesAndNewlines) }
        let scopes = out.components(separatedBy: "\n").first { $0.contains("Token scopes") }?
            .replacingOccurrences(of: "- Token scopes:", with: "").trimmingCharacters(in: .whitespaces) ?? ""
        return login.isEmpty ? nil : Account(login: login, scopes: scopes)
    }

    // MARK: Pull requests

    public static func list(in dir: String, state: String = "open") async throws -> [PullRequest] {
        let out = try await Shell.check("gh", ["pr", "list", "--state", state, "--limit", "30", "--json", PullRequest.listFields], cwd: url(dir))
        return try JSONDecoder().decode([PullRequest].self, from: Data(out.utf8))
    }

    public static func view(_ n: Int, in dir: String) async throws -> PullRequest {
        let out = try await Shell.check("gh", ["pr", "view", String(n), "--json", PullRequest.viewFields], cwd: url(dir))
        return try JSONDecoder().decode(PullRequest.self, from: Data(out.utf8))
    }

    public static func diff(_ n: Int, in dir: String) async throws -> String {
        try await Shell.check("gh", ["pr", "diff", String(n)], cwd: url(dir), timeout: 90)
    }

    public static func checks(_ n: Int, in dir: String) async -> [PullRequest.Check] {
        // `gh pr checks` exits non-zero while checks fail or are pending, so read the output either way.
        guard let r = try? await Shell.run("gh", ["pr", "checks", String(n), "--json", "name,state,link"], cwd: url(dir)),
              let list = try? JSONDecoder().decode([PullRequest.Check].self, from: Data(r.stdout.utf8)) else { return [] }
        return list
    }

    @discardableResult
    public static func create(title: String, body: String, base: String?, draft: Bool, in dir: String) async throws -> String {
        var a = ["pr", "create", "--title", title, "--body", body]
        if let base { a += ["--base", base] }
        if draft { a.append("--draft") }
        return try await Shell.check("gh", a, cwd: url(dir), timeout: 90).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// With `auto`, GitHub merges as soon as the required checks pass.
    public static func merge(_ n: Int, method: MergeMethod, auto: Bool, in dir: String) async throws {
        var a = ["pr", "merge", String(n), "--\(method.rawValue)", "--delete-branch"]
        if auto { a.append("--auto") }
        try await Shell.check("gh", a, cwd: url(dir), timeout: 90)
    }

    public static func review(_ n: Int, action: ReviewAction, body: String, in dir: String) async throws {
        var a = ["pr", "review", String(n), "--\(action.rawValue)"]
        if !body.isEmpty { a += ["--body", body] }
        try await Shell.check("gh", a, cwd: url(dir))
    }

    public static func comment(_ n: Int, body: String, in dir: String) async throws {
        try await Shell.check("gh", ["pr", "comment", String(n), "--body", body], cwd: url(dir))
    }

    public static func openInBrowser(_ n: Int, in dir: String) async { _ = try? await Shell.run("gh", ["pr", "view", String(n), "--web"], cwd: url(dir)) }

    // MARK: Repositories

    public static func repos(limit: Int = 100) async -> [String] {
        guard let out = try? await Shell.check("gh", ["repo", "list", "--limit", String(limit), "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"]) else { return [] }
        return out.split(separator: "\n").map(String.init)
    }

    public static func clone(_ slug: String, into parent: String) async throws -> String {
        let name = String(slug.split(separator: "/").last ?? "")
        let dest = parent + "/" + name
        try await Shell.check("gh", ["repo", "clone", slug, dest], timeout: 600)
        return dest
    }

    public static func issueSummary(_ ref: String, in dir: String) async -> String? {
        guard let out = try? await Shell.check("gh", ["issue", "view", ref, "--json", "title,body,number", "--jq", "\"#\\(.number) \\(.title)\\n\\n\\(.body)\""], cwd: url(dir)) else { return nil }
        return out
    }

    // MARK: Issues

    public struct Issue: Codable, Identifiable, Equatable, Sendable {
        public struct Label: Codable, Equatable, Sendable { public var name: String; public init(name: String) { self.name = name } }
        public struct User: Codable, Equatable, Sendable { public var login: String; public init(login: String) { self.login = login } }
        public struct Comment: Codable, Equatable, Sendable { public var body: String; public var author: User? }
        public var number: Int
        public var title: String
        public var state: String?
        public var body: String?
        public var labels: [Label]?
        public var author: User?
        public var assignees: [User]?
        public var comments: [Comment]?
        public var updatedAt: String?
        public var id: Int { number }
        public init(number: Int, title: String, labels: [Label]? = nil) { self.number = number; self.title = title; self.labels = labels }
        public static let listFields = "number,title,state,labels,author,assignees,updatedAt"

        /// The issue as text an agent can work from: title, description, and the discussion.
        public func requirementText(limit: Int = 8000) -> String {
            var s = "Issue #\(number): \(title)\n\n\(body ?? "")"
            for c in comments ?? [] { s += "\n\n— \(c.author?.login ?? "someone") commented:\n\(c.body)" }
            return s.count > limit ? String(s.prefix(limit)) + "\n…" : s
        }
    }

    public static func issues(in dir: String, state: String = "open", search: String = "") async throws -> [Issue] {
        var a = ["issue", "list", "--state", state, "--limit", "50", "--json", Issue.listFields]
        if !search.isEmpty { a += ["--search", search] }
        let out = try await Shell.check("gh", a, cwd: url(dir), timeout: 60)
        return try JSONDecoder().decode([Issue].self, from: Data(out.utf8))
    }

    public static func issue(_ n: Int, in dir: String) async throws -> Issue {
        let out = try await Shell.check("gh", ["issue", "view", String(n), "--json", "number,title,state,body,labels,author,comments"], cwd: url(dir), timeout: 60)
        return try JSONDecoder().decode(Issue.self, from: Data(out.utf8))
    }

    // MARK: Inbox (across repositories)

    public struct InboxItem: Codable, Identifiable, Equatable, Sendable {
        public struct Repo: Codable, Equatable, Sendable { public var nameWithOwner: String; public var name: String?; public init(nameWithOwner: String, name: String?) { self.nameWithOwner = nameWithOwner; self.name = name } }
        public var number: Int
        public var title: String
        public var repository: Repo
        public var author: Issue.User?
        public var updatedAt: String?
        public var url: String
        public var isDraft: Bool?
        public var id: String { "\(repository.nameWithOwner)#\(number)" }
        public init(number: Int, title: String, repository: Repo, author: Issue.User?, updatedAt: String?, url: String, isDraft: Bool?) {
            self.number = number; self.title = title; self.repository = repository; self.author = author; self.updatedAt = updatedAt; self.url = url; self.isDraft = isDraft
        }
    }

    /// Open pull requests that need you: review requested, and your own.
    public static func inbox() async -> (reviewRequested: [InboxItem], mine: [InboxItem]) {
        async let a = searchPRs("--review-requested=@me")
        async let b = searchPRs("--author=@me")
        return await (a, b)
    }

    static func searchPRs(_ flag: String) async -> [InboxItem] {
        guard let out = try? await Shell.check("gh", ["search", "prs", flag, "--state", "open", "--limit", "30", "--json", "number,title,repository,author,updatedAt,url,isDraft"], timeout: 60),
              let list = try? JSONDecoder().decode([InboxItem].self, from: Data(out.utf8)) else { return [] }
        return list
    }
}
