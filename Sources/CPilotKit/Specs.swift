// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One task in `tasks.md`: `- [ ] T003 Keep offset clients working (R3) needs: T002 branch: spec-014-t003 pr: #223`.
public struct SpecTask: Identifiable, Equatable, Sendable {
    public var id: String                 // T003
    public var title: String
    public var done: Bool
    public var covers: [String] = []      // R3
    public var needs: [String] = []       // T002
    public var branch: String?
    public var pr: Int?
    public init(id: String, title: String, done: Bool, covers: [String] = [], needs: [String] = [], branch: String? = nil, pr: Int? = nil) {
        self.id = id; self.title = title; self.done = done; self.covers = covers; self.needs = needs; self.branch = branch; self.pr = pr
    }
}

public struct SpecDoc: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case draft, planned, ready, inProgress, done
        public var label: String { switch self { case .draft: "Draft"; case .planned: "Planned"; case .ready: "Ready"; case .inProgress: "In progress"; case .done: "Done" } }
    }
    public var id: String                 // 014-cursor-pagination
    public var number: Int
    public var title: String
    public var spec: String?
    public var plan: String?
    public var tasksText: String?
    public var tasks: [SpecTask] { tasksText.map(Specs.parseTasks) ?? [] }
    public var source: String?            // "Issue #214" and so on, from the first "Source:" line
    public var openQuestions: [String] { spec.map(Specs.openQuestions) ?? [] }
    public init(id: String, number: Int, title: String, spec: String?, plan: String?, tasksText: String?, source: String? = nil) {
        self.id = id; self.number = number; self.title = title; self.spec = spec; self.plan = plan; self.tasksText = tasksText; self.source = source
    }
    public var progress: (done: Int, total: Int) { let t = tasks; return (t.filter(\.done).count, t.count) }

    /// Where the spec stands. `merged` holds branches whose pull requests are merged; `started` holds branches that exist.
    public func status(merged: Set<String> = [], started: Set<String> = []) -> Status {
        guard spec != nil else { return .draft }
        let t = tasks
        guard plan != nil else { return .draft }
        guard !t.isEmpty else { return .planned }
        let finished = t.filter { $0.done || ($0.branch.map(merged.contains) ?? false) }
        if finished.count == t.count { return .done }
        if !finished.isEmpty || t.contains(where: { $0.branch.map(started.contains) ?? false }) { return .inProgress }
        return .ready
    }
}

public enum Specs {
    public static let folder = "specs"

    // MARK: Parsing

    public static func parseTasks(_ text: String) -> [SpecTask] {
        var out: [SpecTask] = []
        for raw in text.components(separatedBy: "\n") {
            guard let m = raw.range(of: #"^\s*[-*]\s+\[( |x|X)\]\s+(T\d+)\s+(.+)$"#, options: .regularExpression) else { continue }
            let line = String(raw[m])
            let done = line.contains("[x]") || line.contains("[X]")
            guard let idRange = line.range(of: #"T\d+"#, options: .regularExpression) else { continue }
            let id = String(line[idRange])
            var rest = String(line[idRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var task = SpecTask(id: id, title: "", done: done)
            // Metadata keys (needs:, branch:, pr:) run to the next key or the end of the line.
            if let k = rest.range(of: #"\s(needs|branch|pr):"#, options: .regularExpression) {
                let meta = String(rest[k.lowerBound...]); rest = String(rest[..<k.lowerBound])
                let pattern = try? NSRegularExpression(pattern: #"(needs|branch|pr):\s*(.*?)(?=\s(?:needs|branch|pr):|$)"#)
                let ns = meta as NSString
                for mm in pattern?.matches(in: meta, range: NSRange(location: 0, length: ns.length)) ?? [] {
                    let key = ns.substring(with: mm.range(at: 1)), val = ns.substring(with: mm.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "needs": task.needs = val.split(whereSeparator: { ", ".contains($0) }).map(String.init).filter { $0.hasPrefix("T") }
                    case "branch": task.branch = val.isEmpty ? nil : val
                    default: task.pr = Int(val.replacingOccurrences(of: "#", with: ""))
                    }
                }
            }
            if let c = rest.range(of: #"\((R\d+(?:\s*,\s*R\d+)*)\)\s*$"#, options: .regularExpression) {
                task.covers = rest[c].components(separatedBy: CharacterSet(charactersIn: "(), ")).filter { $0.hasPrefix("R") }
                rest = String(rest[..<c.lowerBound])
            }
            task.title = rest.trimmingCharacters(in: .whitespaces)
            out.append(task)
        }
        return out
    }

    static func render(_ t: SpecTask) -> String {
        var s = "- [\(t.done ? "x" : " ")] \(t.id) \(t.title)"
        if !t.covers.isEmpty { s += " (\(t.covers.joined(separator: ", ")))" }
        if !t.needs.isEmpty { s += " needs: \(t.needs.joined(separator: ", "))" }
        if let b = t.branch { s += " branch: \(b)" }
        if let p = t.pr { s += " pr: #\(p)" }
        return s
    }

    /// Changes one task's line (tick it, record its branch or pull request) and leaves the rest of the file as it was.
    public static func updateTask(_ text: String, id: String, done: Bool? = nil, branch: String? = nil, pr: Int? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            guard let t = parseTasks(lines[i]).first, t.id == id else { continue }
            var u = t
            if let done { u.done = done }
            if let branch { u.branch = branch }
            if let pr { u.pr = pr }
            lines[i] = render(u)
        }
        return lines.joined(separator: "\n")
    }

    /// The questions listed under "Open questions" in a spec.
    public static func openQuestions(_ spec: String) -> [String] {
        var inSection = false, out: [String] = []
        for raw in spec.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { inSection = l.lowercased().contains("open question"); continue }
            guard inSection, l.hasPrefix("-") || l.hasPrefix("*") || l.range(of: #"^\d+[.)]"#, options: .regularExpression) != nil else { continue }
            let q = l.replacingOccurrences(of: #"^([-*]|\d+[.)])\s*(\[[ xX]\]\s*)?"#, with: "", options: .regularExpression)
            if !q.isEmpty, q.lowercased() != "none", q.lowercased() != "none." { out.append(q) }
        }
        return out
    }

    public static func title(of markdown: String) -> String? {
        markdown.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    public static func sourceLine(of markdown: String) -> String? {
        markdown.components(separatedBy: "\n").first { $0.lowercased().hasPrefix("> source:") || $0.lowercased().hasPrefix("source:") }
            .map { $0.replacingOccurrences(of: #"^>?\s*[Ss]ource:\s*"#, with: "", options: .regularExpression) }
    }

    // MARK: Numbering and ordering

    public static func nextNumber(existing ids: [String]) -> Int { (ids.compactMap { Int($0.prefix(while: \.isNumber)) }.max() ?? 0) + 1 }
    public static func folderName(number: Int, title: String) -> String { String(format: "%03d-%@", number, String(Git.slugify(title).prefix(40))) }

    /// Tasks that can start now: not done, not started, and everything they need is finished, either merged or already coded
    /// (its branch has commits), because the next task is stacked on top of it.
    public static func ready(_ tasks: [SpecTask], merged: Set<String> = [], coded: Set<String> = []) -> [SpecTask] {
        let finished = Set(tasks.filter { $0.done || ($0.branch.map { merged.contains($0) || coded.contains($0) } ?? false) }.map(\.id))
        return tasks.filter { t in !t.done && t.branch == nil && t.needs.allSatisfy(finished.contains) }
    }

    /// The branch a task builds on: the latest unfinished dependency's branch, or the trunk when all its dependencies are merged.
    public static func parentBranch(for task: SpecTask, in tasks: [SpecTask], trunk: String, merged: Set<String> = []) -> String {
        for dep in task.needs.reversed() {
            if let t = tasks.first(where: { $0.id == dep }), let b = t.branch, !merged.contains(b), !t.done { return b }
        }
        return trunk
    }

    public static func taskBranch(spec: String, task: SpecTask) -> String { "spec-\(spec.prefix(3))-\(task.id.lowercased())" }

    // MARK: Reading and writing the folder (local or on a server, through the active environment)

    /// Every spec in `<dir>/specs`, read with one command so it is as fast on a server as on this Mac.
    public static func list(in dir: String) async -> (docs: [SpecDoc], constitution: String?) {
        let script = #"cd "$1" 2>/dev/null || exit 0; for f in specs/constitution.md specs/*/source.md specs/*/spec.md specs/*/plan.md specs/*/tasks.md; do if [ -f "$f" ]; then printf '@@FILE %s\n' "$f"; cat "$f"; printf '\n'; fi; done"#
        guard let r = try? await Shell.run("sh", ["-c", script, "sh", dir], timeout: 30), r.ok else { return ([], nil) }
        var files: [String: String] = [:], current: String?, buf: [String] = []
        func flush() { if let c = current { files[c] = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) } }
        for line in r.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("@@FILE ") { flush(); current = String(line.dropFirst(7)); buf = [] } else { buf.append(line) }
        }
        flush()
        var ids = Set<String>()
        for k in files.keys { let p = k.split(separator: "/"); if p.count == 3 { ids.insert(String(p[1])) } }
        let docs = ids.sorted().map { id -> SpecDoc in
            let spec = files["specs/\(id)/spec.md"]
            let src = files["specs/\(id)/source.md"]
            return SpecDoc(id: id, number: Int(id.prefix(while: \.isNumber)) ?? 0, title: spec.flatMap(title(of:)) ?? String(id.drop(while: { $0.isNumber || $0 == "-" })).replacingOccurrences(of: "-", with: " ").capitalized,
                           spec: spec, plan: files["specs/\(id)/plan.md"], tasksText: files["specs/\(id)/tasks.md"],
                           source: spec.flatMap(sourceLine(of:)) ?? src.flatMap(sourceLine(of:)))
        }
        return (docs, files["specs/constitution.md"])
    }

    public static func write(_ relativePath: String, _ text: String, in dir: String) async throws {
        let r = try await Shell.run("sh", ["-c", #"cd "$1" && mkdir -p "$(dirname "$2")" && cat > "$2""#, "sh", dir, relativePath], input: Data(text.utf8), timeout: 30)
        guard r.ok else { throw ShellError.failed(command: "write", status: r.status, stderr: r.stderr) }
    }

    public static let defaultConstitution = """
    # Project principles

    These rules apply to every spec, plan and task in this repository.

    - Keep changes small and reviewable: one pull request per task.
    - Every behavior change has a test that fails without it.
    - Prefer the project's existing patterns and libraries over new ones.
    - Never log or commit secrets.
    """
}

/// What each stage asks the agent. The agent replies with only the document, and CPilot saves it after you approve it.
public enum SpecPrompts {
    public enum Stage: String, Sendable { case specify, plan, tasks }

    static func context(constitution: String?) -> String {
        constitution.map { "Project principles (follow them):\n\($0)\n\n" } ?? ""
    }

    public static func specify(requirement: String, source: String, constitution: String?, answers: String? = nil, previous: String? = nil, assume: Bool = false) -> String {
        var p = context(constitution: constitution)
        p += "You are writing a feature specification. Read the repository as needed to ground it in what exists (read only; do not modify anything). Reply with ONLY the contents of spec.md in Markdown, nothing before or after it.\n\n"
        p += "Use exactly this structure:\n# <short title>\n> Source: \(source)\n## Why\n(the problem and who it is for, 2-4 sentences)\n## Requirements\n- R1 ... (numbered R1, R2, ... each one testable, stated as behavior not implementation)\n## Acceptance checks\n- A1 (R1) ... (how to verify each requirement)\n## Out of scope\n## Open questions\n"
        p += assume ? "(Do not ask questions. Decide sensibly, and list each decision under a final \"## Assumptions\" section. Write \"- none\" under Open questions.)\n\n"
                    : "(Questions you cannot answer from the repository, one per bullet. Write \"- none\" if there are none.)\n\n"
        if let prev = previous, let a = answers, !a.isEmpty {
            p += "Here is the current draft:\n\(prev)\n\nThe user answered the open questions:\n\(a)\n\nRevise the spec with the answers. Move answered questions into the requirements. Keep any question that is still open.\n\n"
        }
        p += "The requirement:\n\(requirement)"
        return p
    }

    public static func plan(spec: String, constitution: String?) -> String {
        context(constitution: constitution) + "Write an implementation plan for this spec. Read the repository to find the real files, modules and patterns (read only; do not modify anything). Reply with ONLY the contents of plan.md in Markdown.\n\nUse this structure:\n# Plan: <title>\n## Approach\n(the chosen design and why, in a short paragraph)\n## Components\n- path or module: what changes and why\n## Data flow\n## Risks\n- risk and how to handle it\n## Test strategy\n\nThe spec:\n\(spec)"
    }

    public static func tasks(spec: String, plan: String, constitution: String?) -> String {
        context(constitution: constitution) + "Break this plan into tasks. Each task must be small enough for one pull request (roughly 300 changed lines or fewer) and independently reviewable. Order them so each builds on the ones it needs. Reply with ONLY the contents of tasks.md.\n\nUse exactly this format, one task per line, no other list items:\n# Tasks: <title>\n- [ ] T001 <imperative title> (R1, R2)\n- [ ] T002 <imperative title> (R2) needs: T001\n\nRules: ids are T001, T002, ...; the parentheses list the requirement ids from the spec the task covers; \"needs:\" lists task ids that must be finished first, only when truly required; tasks that do not depend on each other should not list needs. Include the tests inside the task they test.\n\nThe spec:\n\(spec)\n\nThe plan:\n\(plan)"
    }

    public static func implement(task: SpecTask, spec: SpecDoc, constitution: String?) -> String {
        context(constitution: constitution) + "Implement exactly one task from a spec, in this branch.\n\nTask \(task.id): \(task.title)\(task.covers.isEmpty ? "" : " (covers \(task.covers.joined(separator: ", ")))")\n\nSpec:\n\(spec.spec ?? "")\n\nPlan:\n\(spec.plan ?? "")\n\nDo only this task. Follow the project's patterns, add or update tests, run them, and when they pass commit with the message \"\(task.id): \(task.title)\". Then stop and summarize what you did and anything the reviewer should look at. Do not push."
    }

    /// Takes the document out of an agent's reply: drops any text before the first heading and any code fence around it.
    public static func extractDocument(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n"); if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) } }
        if let h = t.range(of: #"(?m)^# "#, options: .regularExpression) { t = String(t[h.lowerBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
