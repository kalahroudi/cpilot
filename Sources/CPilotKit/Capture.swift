// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Grabs things from the screen and the browser and turns them into attachments for the active session.
public enum Capture {
    /// Interactive region (drag), or a window (press space). Returns nil when the user cancels with Esc.
    public static func screenshot(window: Bool = false, to dir: URL) async -> Attachment? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "capture-\(Int(Date().timeIntervalSince1970)).png"
        let file = dir.appendingPathComponent(name)
        let args = (window ? ["-iw"] : ["-i"]) + ["-x", file.path]
        guard let r = try? await Shell.run("/usr/sbin/screencapture", args, timeout: 120), r.ok,
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return Attachment(kind: .image, title: "Screenshot", value: file.path, source: "Screen")
    }

    /// Title and address of the frontmost tab in a supported browser.
    public static func frontBrowserPage() async -> (title: String, url: String, app: String)? {
        let script = """
        tell application "System Events" to set front to name of first application process whose frontmost is true
        if front is "Safari" then
          tell application "Safari" to return front & "\\n" & (name of front document) & "\\n" & (URL of front document)
        else if front is in {"Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Chromium"} then
          tell application front to return front & "\\n" & (title of active tab of front window) & "\\n" & (URL of active tab of front window)
        else
          return ""
        end if
        """
        guard let r = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 8), r.ok else { return nil }
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard p.count >= 3, !p[2].isEmpty else { return nil }
        return (p[1], p[2], p[0])
    }

    public static func snippet(_ text: String, source: String?) -> Attachment {
        let first = text.split(separator: "\n").first.map(String.init) ?? "Snippet"
        return Attachment(kind: .text, title: String(first.prefix(60)), value: text, source: source)
    }

    public static func link(title: String, url: String, source: String?) -> Attachment {
        Attachment(kind: .link, title: title.isEmpty ? url : title, value: url, source: source)
    }

    /// How attachments reach the agent: images as pictures, everything else as quoted text that names its source.
    public static func compose(message: String, attachments: [Attachment]) -> (text: String, images: [(mediaType: String, data: Data)]) {
        var text = message
        var images: [(String, Data)] = []
        for a in attachments {
            switch a.kind {
            case .image:
                if let d = try? Data(contentsOf: URL(fileURLWithPath: a.value)) { images.append(("image/png", d)) }
            case .text:
                text += "\n\n[\(a.source.map { "From \($0): " } ?? "")\(a.title)]\n```\n\(a.value)\n```"
            case .link:
                text += "\n\nLink: \(a.title) <\(a.value)>"
            case .file:
                text += "\n\nFile: \(a.value)"
            }
        }
        return (text, images)
    }
}
