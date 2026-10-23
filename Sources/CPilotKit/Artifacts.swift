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
    /// Something the app can draw itself: a page, a vector image, a PDF or a picture.
    public var isRenderable: Bool { Artifacts.renderableExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    public var isText: Bool { !isImage && !["pdf", "zip", "gz", "dmg", "bin", "pyc", "o"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}

public enum Artifacts {
    static let renderableExtensions: Set<String> = ["html", "htm", "svg", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// Added to the agent's instructions so it knows the user cannot browse its working folder.
    public static let agentGuidance = """
    CPilot shows files you write to the user. The user usually cannot open your working folder (it may be a hidden worktree or a remote machine), so do not open mockups, pages or images in a browser or with `open`. \
    Write the file (HTML, SVG, PDF or an image) inside the working folder and tell the user its path relative to that folder. CPilot lists it under the files button at the top of the chat with a Render button that draws it in the app. \
    Rewrite the file to change what they see; they press Reload. Keep mockups self-contained: one HTML file with inline CSS and scripts, no build step.
    """

    /// Files named in the assistant's messages (for example "I've opened `docs/mockup/reader.html`") that the app can render, as absolute paths.
    /// Existence is not checked here; the caller decides, because the folder may be on another machine.
    public static func mentionedRenderable(in items: [ChatItem], root: String) -> [ArtifactFile] {
        var found: [String: ArtifactFile] = [:]
        let exts = renderableExtensions.sorted().joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9_./~@+-]+\\.(?:\(exts))\\b", options: [.caseInsensitive]) else { return [] }
        for it in items where it.kind == .assistant {
            let ns = it.text as NSString
            for m in re.matches(in: it.text, range: NSRange(location: 0, length: ns.length)) {
                var p = ns.substring(with: m.range)
                if p.contains("://") || p.hasPrefix("~") { continue }
                if !p.hasPrefix("/") { p = (root.hasSuffix("/") ? root : root + "/") + (p.hasPrefix("./") ? String(p.dropFirst(2)) : p) }
                p = (p as NSString).standardizingPath
                guard p.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
                var f = found[p] ?? ArtifactFile(path: p, created: false, touches: 0, lastTouched: it.ts)
                f.lastTouched = max(f.lastTouched, it.ts)
                found[p] = f
            }
        }
        return Array(found.values)
    }

    /// Files the session wrote plus renderable files it pointed the user to, most recent first.
    public static func shown(from items: [ChatItem], root: String, exists: (String) -> Bool) -> [ArtifactFile] {
        var all = files(from: items)
        let have = Set(all.map(\.path))
        all += mentionedRenderable(in: items, root: root).filter { !have.contains($0.path) && exists($0.path) }
        return all.sorted { $0.lastTouched > $1.lastTouched }
    }

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
