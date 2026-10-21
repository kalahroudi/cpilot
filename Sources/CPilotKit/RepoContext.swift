// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A repository as the app tells them apart: a folder, on this Mac or on a server.
public struct RepoRef: Hashable, Sendable {
    public var dir: String
    public var environment: String?
    public init(dir: String, environment: String? = nil) { self.dir = dir; self.environment = environment }
    /// One identity for caches and per-repository state. The same folder on this Mac and on a server are different repositories.
    public var key: String { dir + "|" + (environment ?? "") }
    /// The reference a `key` was made from.
    public init?(key: String) {
        guard let bar = key.lastIndex(of: "|") else { return nil }
        let env = String(key[key.index(after: bar)...])
        self.init(dir: String(key[..<bar]), environment: env.isEmpty ? nil : env)
    }
}

public enum RepoLabels {
    /// A name for each repository that tells it apart from the others in a picker: the folder name, then enough of the
    /// parent folders to make two repositories called "app" different, and the server's name when it is not this Mac.
    public static func labels(_ repos: [RepoRef], environmentName: (String) -> String? = { _ in nil }) -> [RepoRef: String] {
        func parts(_ r: RepoRef) -> [String] { r.dir.split(separator: "/").map(String.init) }
        func suffix(_ r: RepoRef) -> String { r.environment.flatMap(environmentName).map { " · \($0)" } ?? "" }
        func label(_ r: RepoRef, depth: Int) -> String {
            let p = parts(r)
            let name = p.isEmpty ? "/" : p.suffix(max(1, depth)).joined(separator: "/")
            return name + suffix(r)
        }
        var depth: [RepoRef: Int] = Dictionary(uniqueKeysWithValues: Set(repos).map { ($0, 1) })
        var out: [RepoRef: String] = [:]
        // Deepen only the repositories that still share a label, until they differ or run out of folders.
        for _ in 0..<32 {
            out = Dictionary(uniqueKeysWithValues: depth.map { ($0.key, label($0.key, depth: $0.value)) })
            let clashing = Dictionary(grouping: out.keys, by: { out[$0]! }).values.filter { $0.count > 1 }.flatMap { $0 }
            let deeper = clashing.filter { depth[$0]! < parts($0).count }
            if deeper.isEmpty { break }
            for r in deeper { depth[r]! += 1 }
        }
        return out
    }
}

extension RepoRef {
    /// Folders inside one repository are one repository. `roots` maps a reference's `key` to the top folder git reported for it; a folder
    /// that has not been looked up yet stays as it is. The first appearance keeps its place in the list.
    public static func collapse(_ repos: [RepoRef], roots: [String: String]) -> [RepoRef] {
        var seen = Set<RepoRef>(), out: [RepoRef] = []
        for r in repos {
            let mapped = RepoRef(dir: roots[r.key] ?? r.dir, environment: r.environment)
            if seen.insert(mapped).inserted { out.append(mapped) }
        }
        return out
    }

    /// Whether `path` is this repository's folder or inside it (a session started in a subfolder belongs to the repository).
    public func contains(_ path: String) -> Bool {
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return path == base || path.hasPrefix(base + "/")
    }
}

/// Where one spec stands in the pipeline when nothing is on screen: kept on disk so a restart, or a repository you are not looking at,
/// does not lose it. Everything else (which tasks are started, coded or merged) is read back from git and `tasks.md`.
public struct SpecRunEntry: Codable, Equatable, Sendable {
    public var autonomy: String                 // "step", "plan" or "hands"
    public var stage: String?                   // a stage was being written when CPilot stopped
    public var draftStage: String?              // a written stage waits for approval
    public var draftText: String?
    public var gate = false                     // spec, plan and tasks are written; waiting for "start building"
    public var attempts = 0                     // times the interrupted or failed stage was started again
    public init(autonomy: String, stage: String? = nil, draftStage: String? = nil, draftText: String? = nil, gate: Bool = false, attempts: Int = 0) {
        self.autonomy = autonomy; self.stage = stage; self.draftStage = draftStage; self.draftText = draftText; self.gate = gate; self.attempts = attempts
    }
    public var handsOff: Bool { autonomy == "hands" }
    /// Nothing is left to carry on or to wait for.
    public var isIdle: Bool { !handsOff && stage == nil && draftText == nil && !gate }
}

public struct SpecRunState: Codable, Equatable {
    public private(set) var entries: [String: [String: SpecRunEntry]] = [:]
    public init() {}

    /// Keeps the entry while there is something to carry on or wait for, and forgets it otherwise.
    public mutating func set(_ entry: SpecRunEntry, _ id: String, in scope: String) {
        if entry.isIdle { remove(id, in: scope) } else { entries[scope, default: [:]][id] = entry }
    }

    public mutating func remove(_ id: String, in scope: String) {
        entries[scope]?[id] = nil
        if entries[scope]?.isEmpty == true { entries[scope] = nil }
    }

    public func entry(_ id: String, in scope: String) -> SpecRunEntry? { entries[scope]?[id] }
    /// The specs of one repository that have something to carry on, in a steady order.
    public func pending(in scope: String) -> [(id: String, entry: SpecRunEntry)] { (entries[scope] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    public func hasWork(in scope: String) -> Bool { !(entries[scope] ?? [:]).isEmpty }
    /// Repositories with a spec to carry on.
    public var scopes: [String] { entries.keys.sorted() }

    public static func load(from url: URL) -> SpecRunState {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SpecRunState.self, from: $0) } ?? SpecRunState()
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// What to do with a saved spec when CPilot starts or you open its repository.
public enum SpecResume {
    public enum Action: Equatable, Sendable {
        case drop                                   // the spec's folder is gone
        case settle                                 // nothing to redo; forget the interrupted stage
        case rewrite(stage: String, attempts: Int)  // a stage was being written: write it again
        case giveUp(stage: String, attempts: Int)   // it failed too many times: say so and stop
        case review                                 // a written stage is waiting: approve it if the autonomy says so, else wait for you
        case wait                                   // waiting for you (start building)
        case build                                  // hands-off: carry on building
    }

    public static let maxAttempts = 3

    public static func decide(_ e: SpecRunEntry, docExists: Bool, hasSpec: Bool, hasDraft: Bool) -> Action {
        guard docExists else { return .drop }
        if hasDraft { return .review }
        if let stage = e.stage {
            if stage == "specify", hasSpec { return .settle }               // an answer round was cut short: the spec on disk stands
            if e.attempts >= maxAttempts { return .giveUp(stage: stage, attempts: e.attempts) }
            return .rewrite(stage: stage, attempts: e.attempts + 1)
        }
        if e.gate { return .wait }
        return e.handsOff ? .build : .wait
    }
}

/// When each repository is next worth asking GitHub about. A repository with checks still running is asked every `pending`
/// seconds; every other one only every `idle` seconds, so many repositories do not multiply the requests while one pull request builds.
public struct PollSchedule {
    public var pending: TimeInterval, idle: TimeInterval
    private var next: [String: Date] = [:]
    public init(pending: TimeInterval = 60, idle: TimeInterval = 600) { self.pending = pending; self.idle = idle }

    public func isDue(_ key: String, now: Date = .now) -> Bool { (next[key] ?? .distantPast) <= now }
    public mutating func record(_ key: String, hasPending: Bool, now: Date = .now) { next[key] = now.addingTimeInterval(hasPending ? pending : idle) }
    /// For a repository that could not be read: leave it alone for `seconds`.
    public mutating func postpone(_ key: String, by seconds: TimeInterval, now: Date = .now) { next[key] = now.addingTimeInterval(seconds) }
    public mutating func keep(only keys: Set<String>) { next = next.filter { keys.contains($0.key) } }
}
