// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The rules a pull request must pass before CPilot merges it. Every failed rule comes with a plain sentence for the UI.
public struct MergeGate: Equatable, Sendable {
    public var ready: Bool
    public var reasons: [String]
    public init(ready: Bool, reasons: [String]) { self.ready = ready; self.reasons = reasons }

    public static func evaluate(pr: PullRequest, checks: [PullRequest.Check], scan: SecurityResult?, requireScan: Bool) -> MergeGate {
        var why: [String] = []
        if !pr.isOpen { why.append("The pull request is not open.") }
        if pr.isDraft { why.append("It is still a draft.") }
        if pr.mergeable == "CONFLICTING" { why.append("It has merge conflicts.") }
        if pr.reviewDecision == "CHANGES_REQUESTED" { why.append("Changes were requested.") }
        let failed = checks.filter(\.failed)
        if !failed.isEmpty { why.append("\(failed.count) check\(failed.count == 1 ? "" : "s") failing: " + failed.map(\.name).joined(separator: ", ")) }
        else if checks.contains(where: { !$0.passed }) { why.append("Checks are still running.") }
        if requireScan {
            if let scan {
                if scan.blocksMerge { why.append("\(scan.confirmed.count) confirmed security issue\(scan.confirmed.count == 1 ? "" : "s").") }
            } else { why.append("The security scan has not run yet.") }
        }
        return MergeGate(ready: why.isEmpty, reasons: why)
    }
}
