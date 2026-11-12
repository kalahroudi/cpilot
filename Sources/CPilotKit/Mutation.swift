// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Mutation testing asks whether the tests can fail: a tool changes the code in small ways ("mutants": `<` to `<=`, a check removed) and runs the tests against each. A mutant no test
/// notices is a bug the tests would let through. It measures the tests whoever wrote them, which pass rate and coverage cannot.
/// CPilot does not bundle a tool: a repository names its own in `.cpilot/mutation`, and CPilot runs it on the files a task changed.
public enum Mutation {
    /// `.cpilot/mutation`:
    ///     command: npx stryker run --mutate {files}
    ///     report: reports/mutation/mutation.json
    ///     threshold: 70
    /// `{files}` becomes the task's changed source files. `report` is a mutation-testing JSON report (Stryker and others write it); without one the score is read from the output, and without that the exit code decides.
    public struct Config: Equatable, Sendable {
        public var command: String
        public var report: String?
        public var threshold: Double
        public var timeout: TimeInterval
    }

    public static let defaultThreshold = 70.0
    /// Rounds the tester gets to kill surviving mutants before a person is asked.
    public static let strengthenLimit = 2

    public static func parseConfig(_ text: String) -> Config? {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let colon = l.firstIndex(of: ":") else { continue }
            values[l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let command = values["command"], !command.isEmpty else { return nil }
        let threshold = values["threshold"].flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { min(100, max(0, $0)) } ?? defaultThreshold
        let timeout = values["timeout"].flatMap(Double.init).map { min(7200, max(30, $0)) } ?? 1800
        return Config(command: command, report: values["report"].flatMap { $0.isEmpty ? nil : $0 }, threshold: threshold, timeout: timeout)
    }

    /// The command with `{files}` filled in: each path quoted for the shell. Nil when the command needs files and there are none to mutate.
    public static func command(_ config: Config, files: [String]) -> String? {
        guard config.command.contains("{files}") else { return config.command }
        guard !files.isEmpty else { return nil }
        let quoted = files.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return config.command.replacingOccurrences(of: "{files}", with: quoted)
    }

    /// The source files a diff changed or added: not tests, not deleted, and only those the tool can mutate (`extensions` empty accepts all).
    public static func sourceFiles(diff: String) -> [String] {
        DiffCheck.parse(diff).filter { !$0.deleted && !DiffCheck.isTest($0.path) && !$0.path.hasPrefix(".") && !$0.path.hasSuffix(".md") && !$0.path.hasSuffix(".json") && !$0.path.hasSuffix(".yml") && !$0.path.hasSuffix(".yaml") }.map(\.path)
    }

    public struct Survivor: Equatable, Sendable {
        public var file: String
        public var line: Int
        public var mutator: String
        public var replacement: String?
        public var text: String {
            "\(file):\(line): \(mutator)" + (replacement.map { " (changed to `\($0.prefix(80))`)" } ?? "") + " and no test failed"
        }
    }

    public struct Report: Equatable, Sendable {
        public var killed: Int
        public var survived: Int
        public var noCoverage: Int
        /// Percent of the mutants that could be judged and were caught. 100 when none could be judged.
        public var score: Double
        public var survivors: [Survivor]
    }

    /// A mutation-testing JSON report (the open schema Stryker, Stryker.NET and others write): files → mutants with a status and a location.
    /// A mutant that was killed or timed out is caught; one that survived or had no coverage is missed; the rest (compile errors, ignored) cannot be judged.
    public static func parseReport(_ data: Data) -> Report? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let files = root["files"] as? [String: Any] else { return nil }
        var killed = 0, survived = 0, none = 0
        var survivors: [Survivor] = []
        for (path, f) in files.sorted(by: { $0.key < $1.key }) {
            for m in ((f as? [String: Any])?["mutants"] as? [[String: Any]]) ?? [] {
                let status = (m["status"] as? String) ?? ""
                switch status {
                case "Killed", "Timeout": killed += 1
                case "Survived", "NoCoverage":
                    if status == "Survived" { survived += 1 } else { none += 1 }
                    let line = (((m["location"] as? [String: Any])?["start"]) as? [String: Any])?["line"] as? Int ?? 0
                    survivors.append(Survivor(file: path, line: line, mutator: (m["mutatorName"] as? String) ?? "a change", replacement: m["replacement"] as? String))
                default: break
                }
            }
        }
        let judged = killed + survived + none
        return Report(killed: killed, survived: survived, noCoverage: none, score: judged == 0 ? 100 : Double(killed) * 100 / Double(judged), survivors: survivors)
    }

    /// A score printed in a tool's output ("Mutation score: 82.5%"), the last one if there are several.
    public static func parseScore(_ output: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)(?:mutation\s+score|score)[^0-9\n]{0,20}(\d{1,3}(?:\.\d+)?)\s*%"#) else { return nil }
        let ns = output as NSString
        let m = re.matches(in: output, range: NSRange(location: 0, length: ns.length)).last
        return m.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { min(100, $0) }
    }

    public enum Verdict: Equatable, Sendable {
        case pass(score: Double?)
        /// Mutants the tests miss: the tester is asked to write tests that catch them.
        case strengthen(score: Double, survivors: [Survivor])
        /// The tool could not run, so nothing was measured.
        case unmeasured(String)
    }

    /// What a run came to. `report` is the contents of the report file when there is one.
    public static func judge(_ config: Config, ok: Bool, output: String, report: Data?) -> Verdict {
        if let report, let r = parseReport(report) {
            return r.score >= config.threshold ? .pass(score: r.score) : .strengthen(score: r.score, survivors: r.survivors)
        }
        if let s = parseScore(output) {
            return s >= config.threshold ? .pass(score: s) : .strengthen(score: s, survivors: [])
        }
        return ok ? .pass(score: nil) : .unmeasured("`\(config.command.prefix(80))` failed and printed no mutation score.")
    }

    public static func strengthenPrompt(task: SpecTask, criteria: [Specs.Criterion], score: Double, threshold: Double, survivors: [Survivor]) -> String {
        let reqs = criteria.map { "- \($0.id): \($0.text)" }.joined(separator: "\n")
        let list = survivors.prefix(15).map { "- " + $0.text }.joined(separator: "\n")
        return """
        You are the tester who wrote the locked tests for task \(task.id): \(task.title). The code is written now, and a mutation tool changed it in small ways to see whether your tests notice. They caught \(String(format: "%.0f", score))% of the changes; the bar is \(String(format: "%.0f", threshold))%. These changes got through, so no test would fail if the code had these bugs:

        \(list.isEmpty ? "(The tool printed only the score. Run it yourself to see which changes survive.)" : list)
        \(survivors.count > 15 ? "\n…and \(survivors.count - 15) more.\n" : "")
        The requirements of this task:
        \(reqs)

        Add tests that fail for each of these changes (and for others like them), through the public interface and from the requirements, not by copying what the code does. Change only test files, keep the existing tests as they are, run all of them, and commit with the message "\(task.id) tests: kill surviving mutants". Do not change the code. End with one line `DISPUTE: AMENDED, because <what you added>`.
        """
    }
}
