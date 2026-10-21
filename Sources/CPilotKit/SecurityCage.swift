// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct SecurityFinding: Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    /// Proven by reproducing the attack in a sandbox. Unconfirmed leads never block a merge.
    public var confirmed: Bool
    public var detail: String
}

public struct SecurityResult: Equatable, Sendable {
    public var findings: [SecurityFinding]
    public var report: String
    public var confirmed: [SecurityFinding] { findings.filter(\.confirmed) }
    public var leads: [SecurityFinding] { findings.filter { !$0.confirmed } }
    public var blocksMerge: Bool { !confirmed.isEmpty }
}

/// Runs SecurityCage on a checkout and reads the report it writes. It scans code as data, offline, and proves findings in Docker.
public enum SecurityCage {
    /// "## Fix these" lists problems that were proven; "## We couldn't confirm these" lists leads.
    public static func parse(report: String) -> SecurityResult {
        var findings: [SecurityFinding] = []
        var section = ""
        var current: SecurityFinding?
        func flush() { if let c = current { findings.append(c) }; current = nil }
        for raw in report.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                let h = line.dropFirst(3).lowercased()
                section = h.hasPrefix("fix these") ? "fix" : (h.contains("couldn't confirm") || h.contains("could not confirm")) ? "lead" : ""
                continue
            }
            guard !section.isEmpty else { continue }
            // A new item starts at an unindented heading, bullet or number; indented lines belong to the item above.
            if raw.hasPrefix("### ") || raw.hasPrefix("- ") || raw.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flush()
                let t = raw.replacingOccurrences(of: #"^(###|-|\d+\.)\s+"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "")
                current = SecurityFinding(title: t, confirmed: section == "fix", detail: "")
                continue
            }
            if current != nil, !line.isEmpty { current!.detail += (current!.detail.isEmpty ? "" : "\n") + line }
        }
        flush()
        return SecurityResult(findings: findings, report: report)
    }

    public static func isAvailable() -> Bool { Shell.find("npx") != nil }
    public static func dockerRunning() async -> Bool { (try? await Shell.run("docker", ["info"], timeout: 8))?.ok ?? false }

    /// `prove` reproduces each finding in an isolated container, so it needs Docker. Without it only the offline plan runs.
    public static func scan(folder: String, prove: Bool, onLine: @escaping @Sendable (String) -> Void) async throws -> SecurityResult {
        let args = prove ? ["--yes", "securitycage", "scan", ".", "--prove"] : ["--yes", "securitycage", "plan", "."]
        let status = try await Shell.stream("npx", args, cwd: URL(fileURLWithPath: folder), onLine: onLine)
        let report = (try? String(contentsOfFile: folder + "/.securitycage/scan-report.md", encoding: .utf8)) ?? ""
        if report.isEmpty, status != 0 { throw ShellError.failed(command: "securitycage", status: status, stderr: "The scan did not finish. See the log for details.") }
        return parse(report: report)
    }

    /// The text to hand an agent so it fixes one finding.
    public static func fixPrompt(_ f: SecurityFinding) -> String {
        "Fix this security problem with the smallest safe change, then add a regression test that fails before the fix.\n\n\(f.title)\n\(f.detail)"
    }
}
