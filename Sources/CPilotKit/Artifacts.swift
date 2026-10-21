// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A file a session wrote or changed.
public struct ArtifactFile: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var created: Bool           // written whole, rather than edited
    public var touches: Int
    public var lastTouched: Date
    public var id: String { path }
    public var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    public var isText: Bool { !isImage && !["pdf", "zip", "gz", "dmg", "bin", "pyc", "o"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}

public enum Artifacts {
    static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// The files this session produced, most recently touched first. Rows that failed are ignored.
    public static func files(from items: [ChatItem]) -> [ArtifactFile] {
        var byPath: [String: ArtifactFile] = [:]
        for it in items where it.kind == .tool && it.status != .failed {
            guard let tool = it.title, writeTools.contains(tool), let p = it.detail, !p.isEmpty, p.hasPrefix("/") else { continue }
            var f = byPath[p] ?? ArtifactFile(path: p, created: false, touches: 0, lastTouched: it.ts)
            f.touches += 1; f.lastTouched = max(f.lastTouched, it.ts)
            if tool == "Write" { f.created = true }
            byPath[p] = f
        }
        return byPath.values.sorted { $0.lastTouched > $1.lastTouched }
    }

    /// The path relative to the session's folder, for display.
    public static func display(_ path: String, root: String) -> String {
        let r = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
    }
}
