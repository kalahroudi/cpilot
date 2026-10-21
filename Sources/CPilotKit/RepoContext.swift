// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A repository as the app tells them apart: a folder, on this Mac or on a server.
public struct RepoRef: Hashable, Sendable {
    public var dir: String
    public var environment: String?
    public init(dir: String, environment: String? = nil) { self.dir = dir; self.environment = environment }
    /// One identity for caches and per-repository state. The same folder on this Mac and on a server are different repositories.
    public var key: String { dir + "|" + (environment ?? "") }
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

/// State that belongs to one repository and is looked up by an id inside it (the spec pipeline's jobs, for example).
/// Two repositories can have the same ids, and work that finishes after you switched repository must land in the repository it started in.
public struct ScopedStore<Value> {
    private var items: [String: [String: Value]] = [:]
    public init() {}

    public subscript(scope: String, id: String) -> Value? {
        get { items[scope]?[id] }
        set { items[scope, default: [:]][id] = newValue; if newValue == nil, items[scope]?.isEmpty == true { items[scope] = nil } }
    }

    public func all(in scope: String) -> [String: Value] { items[scope] ?? [:] }

    /// Changes the value in that scope, starting from `new` when it has none yet.
    public mutating func modify(_ scope: String, _ id: String, new: @autoclosure () -> Value, _ change: (inout Value) -> Void) {
        var v = items[scope]?[id] ?? new()
        change(&v)
        items[scope, default: [:]][id] = v
    }

    /// Changes the value only when it exists. Late news about work that was discarded does not bring it back.
    public mutating func modifyExisting(_ scope: String, _ id: String, _ change: (inout Value) -> Void) {
        guard var v = items[scope]?[id] else { return }
        change(&v)
        items[scope]?[id] = v
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

/// The specs CPilot is building without asking, per repository, so a restart or a switch to another repository picks them up again.
/// Everything else (which tasks are started, coded or merged) is read back from git and `tasks.md`.
public struct SpecRunState: Codable, Equatable {
    public private(set) var handsOff: [String: [String]] = [:]
    public init() {}

    public mutating func arm(_ id: String, in scope: String) {
        if handsOff[scope]?.contains(id) != true { handsOff[scope, default: []].append(id) }
    }

    /// The spec is handed on (pull requests open and auto-merge on), finished, or gone.
    public mutating func finish(_ id: String, in scope: String) {
        handsOff[scope]?.removeAll { $0 == id }
        if handsOff[scope]?.isEmpty == true { handsOff[scope] = nil }
    }

    public func pending(in scope: String) -> [String] { handsOff[scope] ?? [] }
    public func hasWork(in scope: String) -> Bool { !(handsOff[scope] ?? []).isEmpty }

    public static func load(from url: URL) -> SpecRunState {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SpecRunState.self, from: $0) } ?? SpecRunState()
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
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
