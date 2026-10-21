// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct SecurityFinding: Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    /// Proven by reproducing the attack in a sandbox. Unconfirmed leads never block a merge.
    public var confirmed: Bool
    public var detail: String
    /// SecurityCage's own ready-made prompt for fixing this, when it gave one.
    public var prompt: String?
    public var severity: String?
    public init(title: String, confirmed: Bool, detail: String, prompt: String? = nil, severity: String? = nil) { self.title = title; self.confirmed = confirmed; self.detail = detail; self.prompt = prompt; self.severity = severity }
}

public struct SecurityResult: Equatable, Sendable {
    public var findings: [SecurityFinding]
    public var report: String
    public init(findings: [SecurityFinding], report: String) { self.findings = findings; self.report = report }
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

    /// The command line of a local checkout of SecurityCage: `<folder>/packages/cli/src/cli.ts`. CPilot never fetches it from a package
    /// registry, because a name there can belong to someone else.
    public static func locate(configured: String?) -> String? {
        let home = NSHomeDirectory()
        var candidates = [configured, ProcessInfo.processInfo.environment["SECURITYCAGE_HOME"], home + "/securitycage", home + "/code/securitycage", home + "/src/securitycage"]
        candidates.removeAll { $0 == nil || $0!.isEmpty }
        for c in candidates.compactMap({ $0 }) {
            let cli = (c as NSString).expandingTildeInPath + "/packages/cli/src/cli.ts"
            if FileManager.default.fileExists(atPath: cli), FileManager.default.fileExists(atPath: (c as NSString).expandingTildeInPath + "/node_modules") { return cli }
        }
        return nil
    }

    /// The free, offline plan (`.securitycage/plan.md`): problems under "Worth fixing now", each with a severity, why it matters,
    /// where it is and a fix prompt. Critical and high findings from these deterministic checks block a merge; lower ones are notes.
    public static func parsePlan(_ md: String) -> SecurityResult {
        var findings: [SecurityFinding] = []
        var inSection = false, inPrompt = false, inWhere = false
        var cur: SecurityFinding?
        var prompt: [String] = []
        func flush() { if var c = cur { c.prompt = prompt.isEmpty ? nil : prompt.joined(separator: "\n"); findings.append(c) }; cur = nil; prompt = []; inPrompt = false; inWhere = false }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") { flush(); inSection = line.lowercased().hasPrefix("## worth fixing now"); continue }
            guard inSection else { continue }
            if raw.hasPrefix("### ") {
                flush()
                let t = String(raw.dropFirst(4)).replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
                cur = SecurityFinding(title: t, confirmed: false, detail: "")
                continue
            }
            guard cur != nil else { continue }
            if line.hasPrefix("```") { inPrompt.toggle(); continue }
            if inPrompt { prompt.append(raw); continue }
            if line.hasPrefix("**Severity:**") {
                let sev = line.replacingOccurrences(of: "**Severity:**", with: "").components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                cur?.severity = sev; cur?.confirmed = sev == "critical" || sev == "high"
            } else if line.hasPrefix("**Why it matters:**") { cur?.detail += line.replacingOccurrences(of: "**Why it matters:**", with: "").trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("**Where:**") { inWhere = true }
            else if inWhere, line.hasPrefix("- ") { cur?.detail += "\n" + line.dropFirst(2).replacingOccurrences(of: "`", with: "") }
            else if line.hasPrefix("**") { inWhere = false }
        }
        flush()
        return SecurityResult(findings: findings, report: md)
    }

    public static func isAvailable(configured: String? = nil) -> Bool { Shell.find("node") != nil && locate(configured: configured) != nil }
    public static func dockerRunning() async -> Bool { (try? await Shell.run("docker", ["info"], timeout: 8))?.ok ?? false }

    // MARK: Local models (no API key, no cloud)

    public static let defaultModelURL = "http://localhost:8080/v1"

    /// The models an OpenAI-compatible local server (mlxplayer, Ollama, and so on) offers, or nil when nothing answers.
    public static func localModels(baseURL: String = defaultModelURL) async -> [String]? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/models") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 2.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = obj["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }

    /// An instruction-tuned coding model if there is one; a base model that only continues text is a poor choice for triage.
    public static func pickModel(_ models: [String]) -> String? {
        let l = models.map { ($0, $0.lowercased()) }
        return l.first { $0.1.contains("coder") && $0.1.contains("instruct") }?.0 ?? l.first { $0.1.contains("instruct") }?.0 ?? l.first { !$0.1.hasSuffix("-pt") && !$0.1.contains("-pt-") }?.0 ?? models.first
    }

    public static func localEnvironment(baseURL: String, model: String) -> [String: String] {
        ["SECURITYCAGE_MODEL_PROVIDER": "mlx", "MLX_BASE_URL": baseURL, "SECURITYCAGE_TRIAGE_MODEL": model, "SECURITYCAGE_VERIFY_MODEL": model]
    }

    public struct Mode: Equatable, Sendable {
        public var deep: Bool
        public var environment: [String: String]
        /// What to tell the user about how the scan runs.
        public var note: String
    }

    /// Deep scan with sandboxed proofs when a local model server and Docker (or Colima) are both up; the free offline plan otherwise.
    public static func chooseMode(baseURL: String = defaultModelURL, preferredModel: String = "", dockerUp: Bool? = nil) async -> Mode {
        let docker: Bool
        if let dockerUp { docker = dockerUp } else { docker = await dockerRunning() }
        guard let models = await localModels(baseURL: baseURL), let model = preferredModel.isEmpty ? pickModel(models) : preferredModel else {
            return Mode(deep: false, environment: [:], note: "No local model server answered at \(baseURL), so this is the free offline plan. Start mlxplayer (or Ollama) for the deep scan.")
        }
        guard docker else { return Mode(deep: false, environment: [:], note: "A local model is ready (\(model)) but Docker is not running, so this is the offline plan. Start Colima for proofs.") }
        return Mode(deep: true, environment: localEnvironment(baseURL: baseURL, model: model), note: "Deep scan with \(model) on this Mac, with proofs in Docker. Nothing leaves your machine.")
    }

    public static let setupHint = "Set the SecurityCage folder in Settings → GitHub. Clone github.com/kalahroudi/securitycage, run npm install in it, and choose that folder."

    /// Runs the offline plan, or with `deep` the model-backed scan with sandboxed proofs (which needs Docker and an API key).
    public static func scan(folder: String, deep: Bool = false, environment: [String: String] = [:], configured: String? = nil, onLine: @escaping @Sendable (String) -> Void) async throws -> SecurityResult {
        guard Exec.environment == nil else { throw ShellError.failed(command: "securitycage", status: 1, stderr: "Security scans run on this Mac. Open the repository here to scan it.") }
        guard Shell.find("node") != nil else { throw ShellError.toolNotFound("node") }
        guard let cli = locate(configured: configured) else { throw ShellError.failed(command: "securitycage", status: 1, stderr: setupHint) }
        let args = deep ? [cli, "scan", ".", "--prove", "--max-cost", "2"] : [cli, "plan", "."]   // local models cost $0; the CLI still wants a cap
        let status = try await Shell.stream("node", args, cwd: URL(fileURLWithPath: folder), env: environment, onLine: onLine)
        let deepReport = (try? String(contentsOfFile: folder + "/.securitycage/scan-report.md", encoding: .utf8)) ?? ""
        let planReport = (try? String(contentsOfFile: folder + "/.securitycage/plan.md", encoding: .utf8)) ?? ""
        if deep, !deepReport.isEmpty { return parse(report: deepReport) }
        if planReport.isEmpty, status != 0 { throw ShellError.failed(command: "securitycage", status: status, stderr: "The scan did not finish. See the log for details.") }
        guard !planReport.isEmpty else { throw ShellError.failed(command: "securitycage", status: status, stderr: "The scan finished but wrote no report.") }
        return parsePlan(planReport)
    }

    /// The text to hand an agent so it fixes one finding.
    public static func fixPrompt(_ f: SecurityFinding) -> String {
        if let p = f.prompt, !p.isEmpty { return p + "\n\nThen add a regression test that fails without the fix."}
        return "Fix this security problem with the smallest safe change, then add a regression test that fails before the fix.\n\n\(f.title)\n\(f.detail)"
    }
}
