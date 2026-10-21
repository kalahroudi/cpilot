// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What an agent may do without asking. One level per session, with per-project rules in `AccessPolicy`.
public enum AccessLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case readOnly, askFirst, editFiles, fullAccess
    public var id: String { rawValue }
    public var label: String {
        switch self { case .readOnly: "Read only"; case .askFirst: "Ask first"; case .editFiles: "Edit files"; case .fullAccess: "Full access" }
    }
    public var detail: String {
        switch self {
        case .readOnly: "The agent can read and answer. It cannot change anything."
        case .askFirst: "Reads are free. Every edit, command or network call shows an approval card."
        case .editFiles: "Edits inside the project folder run freely. Commands still ask."
        case .fullAccess: "No prompts. Use only in a throwaway folder. Needs Touch ID to turn on."
        }
    }
    /// The matching Claude CLI permission mode.
    public var claudeMode: String {
        switch self { case .readOnly: "plan"; case .askFirst: "manual"; case .editFiles: "acceptEdits"; case .fullAccess: "bypassPermissions" }
    }
}

/// Which engine drives a session: the Claude command line, or any agent that speaks ACP.
public struct Backend: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case claude, acp }
    public var kind: Kind
    /// Id of a configured ACP agent (see `AcpAgentConfig`). Nil for Claude.
    public var acpAgent: String?
    public static let claude = Backend(kind: .claude, acpAgent: nil)
    public static func acp(_ id: String) -> Backend { Backend(kind: .acp, acpAgent: id) }
}

public struct SessionMeta: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String
    public var backend: Backend
    public var model: String?
    public var access: AccessLevel
    public var branch: String?
    public var worktree: String?
    /// The agent's own session id, used to resume with full context.
    public var remoteId: String?
    public var planMode = false
    public var archived = false
    /// Unsent text in the composer, kept so a crash or restart does not lose it.
    public var draft: String?
    /// A summary of earlier work, placed before this session's first message (a fork or a switch of agent).
    public var handoff: String?
    /// The next start forks the agent's own session instead of continuing it.
    public var forkPending: Bool?
    /// The last recap, the number of chat rows it covered, and its one-line form for lists.
    public var recap: String?
    public var recapRows: Int?
    public var recapHeadline: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String, cwd: String, backend: Backend = .claude, model: String? = nil,
                access: AccessLevel = .askFirst, branch: String? = nil, worktree: String? = nil, remoteId: String? = nil) {
        self.id = id; self.title = title; self.cwd = cwd; self.backend = backend; self.model = model
        self.access = access; self.branch = branch; self.worktree = worktree; self.remoteId = remoteId
        createdAt = .now; updatedAt = .now
    }

    /// The folder commands run in: the worktree when there is one.
    public var workingDirectory: String { worktree ?? cwd }
    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

/// Something attached to a message: a screenshot, a snippet, a link, a file.
public struct Attachment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, text, link, file }
    public var id = UUID().uuidString
    public var kind: Kind
    public var title: String
    /// Text content, the URL, or the path of the saved file.
    public var value: String
    public var source: String?
    public init(kind: Kind, title: String, value: String, source: String? = nil) {
        self.kind = kind; self.title = title; self.value = value; self.source = source
    }
}

/// One row in the chat. Rows are upserted by id, so a streaming reply is one row that grows.
public struct ChatItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, thinking, tool, permission, notice, error }
    public enum Status: String, Codable, Sendable { case running, done, failed, pending, allowed, denied }
    public var id: String
    public var kind: Kind
    public var text: String
    /// Tool name, or the permission headline.
    public var title: String?
    /// Tool input summary, for example the command.
    public var detail: String?
    public var status: Status?
    public var attachments: [Attachment] = []
    public var ts: Date

    public init(id: String = UUID().uuidString, kind: Kind, text: String = "", title: String? = nil, detail: String? = nil,
                status: Status? = nil, attachments: [Attachment] = [], ts: Date = .now) {
        self.id = id; self.kind = kind; self.text = text; self.title = title; self.detail = detail
        self.status = status; self.attachments = attachments; self.ts = ts
    }
}

public extension Array where Element == ChatItem {
    /// Insert or replace by id, keeping order.
    mutating func upsert(_ item: ChatItem) {
        if let i = lastIndex(where: { $0.id == item.id }) { self[i] = item } else { append(item) }
    }
}

/// Sessions live on disk: `meta.json` plus an append-only `transcript.jsonl`. Only the visible tab ever loads a transcript,
/// so ten sessions cost about what one does.
public final class SessionStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public init(root: URL = AppPaths().sessionsDir) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public func list(includeArchived: Bool = false) -> [SessionMeta] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { load($0) }
            .filter { includeArchived || !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("meta.json")) else { return nil }
        return try? decoder.decode(SessionMeta.self, from: data)
    }

    public func save(_ meta: SessionMeta) {
        lock.lock(); defer { lock.unlock() }
        let d = dir(meta.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? encoder.encode(meta) { try? data.write(to: d.appendingPathComponent("meta.json"), options: .atomic) }
    }

    public func delete(_ id: String) { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: dir(id)) }

    public func attachmentsDir(_ id: String) -> URL {
        let d = dir(id).appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Append the final form of an item. Later lines with the same id replace earlier ones when loading.
    public func append(_ item: ChatItem, to id: String) {
        lock.lock(); defer { lock.unlock() }
        let file = dir(id).appendingPathComponent("transcript.jsonl")
        try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        guard var line = try? encoder.encode(item) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// The last `limit` rows of the transcript.
    public func items(_ id: String, limit: Int = 400) -> [ChatItem] {
        guard let text = try? String(contentsOf: dir(id).appendingPathComponent("transcript.jsonl"), encoding: .utf8) else { return [] }
        var out: [ChatItem] = []
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8), let item = try? decoder.decode(ChatItem.self, from: d) { out.upsert(item) }
        }
        return Array(out.suffix(limit))
    }
}
