// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DiffLine: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case context, added, removed, hunk }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
}

public struct DiffFile: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var additions = 0
    public var deletions = 0
    public var isBinary = false
    public var isNew = false
    public var isDeleted = false
    public var lines: [DiffLine] = []
}

/// Reads the output of `git diff` / `gh pr diff` into files and lines the UI can draw.
public enum DiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var oldN = 0, newN = 0, counter = 0
        func flush() { if let c = cur { files.append(c) }; cur = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                let parts = line.dropFirst(11).components(separatedBy: " b/")
                let new = parts.last ?? ""
                let old = parts.first.map { $0.hasPrefix("a/") ? String($0.dropFirst(2)) : $0 }
                cur = DiffFile(path: new, oldPath: old == new ? nil : old)
                continue
            }
            guard cur != nil else { continue }
            if line.hasPrefix("new file mode") { cur?.isNew = true }
            else if line.hasPrefix("deleted file mode") { cur?.isDeleted = true }
            else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { cur?.isBinary = true }
            else if line.hasPrefix("rename to ") { cur?.path = String(line.dropFirst(10)) }
            else if line.hasPrefix("@@") {
                // @@ -12,6 +12,8 @@ context
                let nums = line.split(separator: " ").filter { $0.hasPrefix("-") || $0.hasPrefix("+") }.prefix(2)
                func start(_ s: Substring) -> Int { Int(s.dropFirst().split(separator: ",").first ?? "0") ?? 0 }
                if nums.count == 2 { oldN = start(nums[0]); newN = start(nums[1]) }
                counter += 1
                cur?.lines.append(DiffLine(id: counter, kind: .hunk, text: line))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                counter += 1; cur?.additions += 1
                cur?.lines.append(DiffLine(id: counter, kind: .added, text: String(line.dropFirst()), newNumber: newN)); newN += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                counter += 1; cur?.deletions += 1
                cur?.lines.append(DiffLine(id: counter, kind: .removed, text: String(line.dropFirst()), oldNumber: oldN)); oldN += 1
            } else if line.hasPrefix(" ") {
                counter += 1
                cur?.lines.append(DiffLine(id: counter, kind: .context, text: String(line.dropFirst()), oldNumber: oldN, newNumber: newN)); oldN += 1; newN += 1
            }
        }
        flush()
        return files
    }
}
