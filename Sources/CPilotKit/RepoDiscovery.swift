// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finding repositories a phone may pick: git folders on this Mac that CPilot has not been shown yet, and GitHub names that are safe to clone.
public enum RepoDiscovery {
    /// Where people usually keep code, besides the folder CPilot clones into.
    public static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        ["code", "Developer", "Projects", "src", "dev", "repos", "Documents/GitHub"].map { home + "/" + $0 }
    }

    /// Git folders directly inside each root (not deeper), minus `exclude` and any folder inside one of them. Sorted by folder name.
    public static func scan(roots: [String], exclude: [String] = [], fm: FileManager = .default) -> [String] {
        let skip = Set(exclude.map(standard))
        var found: [String] = []
        var seen = Set<String>()
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let dir = standard(root + "/" + name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir), !seen.contains(dir), !skip.contains(dir) else { continue }
                seen.insert(dir); found.append(dir)
            }
        }
        return found.sorted { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// `owner/name` as GitHub spells it: letters, digits, `.`, `_` and `-`, and neither part starting with a dash or being `.` or `..`.
    public static func isSlug(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && !p.hasPrefix("-") && p != "." && p != ".." && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// Accepts `owner/name`, `https://github.com/owner/name(.git)` and `git@github.com:owner/name.git`.
    public static func slug(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "github.com/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)); break
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        while s.hasSuffix("/") { s.removeLast() }
        return isSlug(s) ? s : nil
    }

    private static func standard(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
}
