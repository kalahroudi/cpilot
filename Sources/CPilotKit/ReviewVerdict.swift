// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a reviewer says at the end of its report, in a form the chief pilot and the merge rules can read without guessing from prose:
/// `VERDICT: CLEAN`, or `VERDICT: OPEN` followed by a `- ` line for each issue it did not fix.
public enum ReviewVerdict: Equatable, Sendable {
    case clean
    case open([String])

    public var label: String { if case .clean = self { "clean" } else { "open" } }
    public var issues: [String] { if case .open(let i) = self { i } else { [] } }

    /// The last verdict in a report, or nil when it has none (an older reviewer, or one that ignored the format).
    public static func parse(_ report: String) -> ReviewVerdict? {
        let lines = report.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.range(of: #"^\W*VERDICT\W*:?\s*(CLEAN|OPEN)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
        if lines[i].range(of: "CLEAN", options: .caseInsensitive) != nil, lines[i].range(of: "OPEN", options: .caseInsensitive) == nil { return .clean }
        var issues: [String] = []
        for line in lines[(i + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") { issues.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            else if !t.isEmpty { break }
        }
        // "OPEN" with nothing listed is still open: the reviewer said it was not done.
        return .open(issues)
    }

    /// The requirement ids the report never mentions. A reviewer that gave a verdict without answering for a requirement did not check it.
    public static func unaddressed(report: String, ids: [String]) -> [String] {
        ids.filter { report.range(of: "\\b\($0)\\b", options: .regularExpression) == nil }
    }

    /// The format a reviewer is asked to end its report with.
    public static let instructions = "End the report with a last line that is exactly `VERDICT: CLEAN` when a full pass found nothing left to fix, or `VERDICT: OPEN` followed by one line starting with \"- \" for each issue you did not fix (and why). Nothing comes after it."
}
