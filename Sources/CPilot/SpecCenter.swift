// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Where a new piece of work comes from. Every kind ends at the same draft spec.
struct SpecSource {
    var label: String                      // "Issue #214", "Described by you", ...
    var title: String
    var requirement: String
    var images: [(mediaType: String, data: Data)] = []
}

enum Autonomy: String, CaseIterable {
    case step, plan, hands
    var label: String { switch self { case .step: "Step by step"; case .plan: "Plan for me"; case .hands: "Hands-off until review" } }
    var detail: String {
        switch self {
        case .step: "Pauses after each stage so you can edit and approve it."
        case .plan: "Writes the spec, plan and tasks by itself and stops once for you to approve them before any code is written."
        case .hands: "Runs everything through a stack of pull requests. Stops for your spec approval, access approvals, and the merge."
        }
    }
}

/// The spec pipeline: idea, spec, questions, plan, tasks, then one session per task on stacked branches.
/// Documents are written by a read-only agent and saved only after you approve them (or automatically, depending on the autonomy).
@MainActor @Observable
final class SpecCenter {
    static let shared = SpecCenter()

    struct Draft: Equatable { var stage: SpecPrompts.Stage; var text: String }
    struct Job {
        var running = false
        var stage = ""
        var status = ""
        var draft: Draft?
        var error: String?
        var gate: Bool = false                  // spec, plan and tasks are written; waiting for "start building"
        var autonomy: Autonomy = .step
        var submitting = false
        /// The result of the last Submit stack: a line to show next to the button, and whether it failed.
        var submitNote: String?
        var submitFailed = false
    }

    var repo: PRCenter.Repo?
    var docs: [SpecDoc] = []
    var constitution: String?
    var selected: String?
    var jobs: [String: Job] = [:]
    var issues: [GitHub.Issue] = []
    var issuesLoading = false
    var issueError: String?
    var merged: Set<String> = []
    var started: Set<String> = []
    var coded: Set<String> = []
    /// Branches with code that has no open pull request yet, or commits the remote has not seen.
    var unsubmitted: Set<String> = []
    var trunk = "main"
    var newWork = false
    var preset: SpecSource?
    var loading = false
    var lastRefresh: Date?
    /// GitHub is queried on every refresh, so repeated refreshes inside this window are skipped.
    static let cooldown: TimeInterval = 60
    var env: EnvironmentConfig? { Workspace.shared.environment(repo?.environment) }
    private var taskSessions: [String: String] = [:]      // "specId/T003" -> session id

    func doc(_ id: String?) -> SpecDoc? { docs.first { $0.id == id } }
    func status(_ d: SpecDoc) -> SpecDoc.Status { d.status(merged: merged, started: started) }

    // MARK: Loading

    func open(_ r: PRCenter.Repo) async { repo = r; Project.shared.current = r; selected = nil; await refresh() }

    /// True when the last refresh is recent enough that another would only spend rate limit.
    var fresh: Bool { lastRefresh.map { Date().timeIntervalSince($0) < Self.cooldown } ?? false }

    /// Refresh on request. Inside the cooldown it tells the user instead of calling GitHub again.
    func refreshIfStale(manual: Bool) async {
        if loading { return }
        if fresh {
            if manual, let t = lastRefresh { AppModel.shared.show("Already refreshed \(Int(Date().timeIntervalSince(t)))s ago. Try again in \(Int(Self.cooldown - Date().timeIntervalSince(t)) + 1)s.", error: false) }
            return
        }
        await refresh()
    }

    func refresh() async {
        guard let r = repo else { return }
        loading = true; defer { loading = false; lastRefresh = Date() }
        let e = env
        let (list, const) = await Exec.with(e) { await Specs.list(in: r.dir) }
        docs = list; constitution = const
        let stacks = await Exec.with(e) { await Stacks.load(in: r.dir, host: LiveStackHost(dir: r.dir)) }
        trunk = stacks.first?.trunk ?? "main"
        merged = Set(stacks.flatMap(\.branches).filter(\.isMerged).map(\.name))
        started = Set(stacks.flatMap(\.branches).map(\.name))
        coded = Set(stacks.flatMap(\.branches).filter { $0.commits > 0 }.map(\.name))
        unsubmitted = Set(stacks.flatMap(\.unsubmitted).map(\.name))
        // A task whose pull request merged is ticked off.
        for d in docs { await tickMerged(d) }
        if selected == nil { selected = docs.last?.id }
    }

    private func tickMerged(_ d: SpecDoc) async {
        guard let r = repo, var text = d.tasksText else { return }
        var changed = false
        for t in d.tasks where !t.done && (t.branch.map(merged.contains) ?? false) { text = Specs.updateTask(text, id: t.id, done: true); changed = true }
        guard changed else { return }
        try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(d.id)/tasks.md", text, in: r.dir) }
        if let i = docs.firstIndex(where: { $0.id == d.id }) { docs[i].tasksText = text }
    }

    func loadIssues(search: String = "") async {
        guard let r = repo else { return }
        issuesLoading = true; issueError = nil; defer { issuesLoading = false }
        do { issues = try await Exec.with(env) { try await GitHub.issues(in: r.dir, search: search) } }
        catch { issueError = AppModel.shared.capture(error, action: "Load issues"); issues = [] }
    }

    // MARK: Starting new work

    func start(_ source: SpecSource, autonomy: Autonomy, allowGit: Bool = false) async {
        guard let r = repo else { return }
        let e = env
        let number = Specs.nextNumber(existing: docs.map(\.id))
        let id = Specs.folderName(number: number, title: source.title)
        do {
            try await Exec.with(e) {
                if constitution == nil { try await Specs.write("\(Specs.folder)/constitution.md", Specs.defaultConstitution, in: r.dir) }
                try await Specs.write("\(Specs.folder)/\(id)/source.md", "> Source: \(source.label)\n\n\(source.requirement)\n", in: r.dir)
            }
        } catch { AppModel.shared.failQuietly(error, action: "Create the spec"); return }
        if allowGit, autonomy == .hands { Workspace.shared.allowCommands(["git add", "git commit", "git status", "git diff"], for: r.dir) }
        await refresh()
        selected = id
        jobs[id] = Job(autonomy: autonomy)
        await run(id, .specify, requirement: source.requirement, label: source.label, images: source.images)
    }

    // MARK: Stages

    private func requirement(for id: String, fallback: String?) async -> (text: String, label: String) {
        guard let r = repo else { return (fallback ?? "", "Described by you") }
        let out = try? await Exec.with(env) { try await Shell.check("cat", ["\(Specs.folder)/\(id)/source.md"], cwd: URL(fileURLWithPath: r.dir)) }
        let t = out ?? fallback ?? ""
        return (t, Specs.sourceLine(of: t) ?? "Described by you")
    }

    func run(_ id: String, _ stage: SpecPrompts.Stage, requirement: String? = nil, label: String? = nil, answers: String? = nil,
             images: [(mediaType: String, data: Data)] = []) async {
        guard let r = repo else { return }
        var job = jobs[id] ?? Job()
        job.running = true; job.stage = stage.rawValue; job.status = "Starting…"; job.error = nil; job.draft = nil; job.gate = false
        jobs[id] = job
        let d = doc(id)
        let assume = job.autonomy != .step
        let prompt: String
        switch stage {
        case .specify:
            var req = requirement ?? ""
            if requirement == nil { req = (await self.requirement(for: id, fallback: nil)).text }
            prompt = SpecPrompts.specify(requirement: req, source: label ?? "Described by you", constitution: constitution, answers: answers, previous: answers == nil ? nil : d?.spec, assume: assume)
        case .plan: prompt = SpecPrompts.plan(spec: d?.spec ?? "", constitution: constitution)
        case .tasks: prompt = SpecPrompts.tasks(spec: d?.spec ?? "", plan: d?.plan ?? "", constitution: constitution)
        }
        do {
            let reply = try await SpecStageRunner.run(prompt: prompt, cwd: r.dir, environment: env, images: images) { [weak self] p in Task { @MainActor in self?.jobs[id]?.status = p } }
            let text = SpecPrompts.extractDocument(reply)
            if stage == .tasks, Specs.parseTasks(text).isEmpty { throw SpecStageError.failed("The agent did not write any tasks in the expected format. Try again.") }
            if stage == .specify, Specs.title(of: text) == nil { throw SpecStageError.failed("The agent did not write a spec. Try again.") }
            jobs[id]?.running = false; jobs[id]?.status = ""
            jobs[id]?.draft = Draft(stage: stage, text: text)
            if shouldAutoApprove(id, stage, text) { await approve(id, text: text) }
        } catch {
            jobs[id]?.running = false; jobs[id]?.error = AppModel.shared.capture(error, action: "Write the \(stage.rawValue)")
        }
    }

    private func shouldAutoApprove(_ id: String, _ stage: SpecPrompts.Stage, _ text: String) -> Bool {
        switch jobs[id]?.autonomy ?? .step {
        case .step: return false
        case .plan: return true
        case .hands: return stage != .specify            // the spec is the one thing you approve
        }
    }

    func approve(_ id: String, text: String) async {
        guard let r = repo, let draft = jobs[id]?.draft else { return }
        let file = draft.stage == .specify ? "spec.md" : draft.stage == .plan ? "plan.md" : "tasks.md"
        do { try await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(file)", text, in: r.dir) } }
        catch { jobs[id]?.error = AppModel.shared.capture(error, action: "Save the \(file)"); return }
        jobs[id]?.draft = nil
        await refresh()
        await advance(id, after: draft.stage)
    }

    func discard(_ id: String) { jobs[id]?.draft = nil }

    private func advance(_ id: String, after stage: SpecPrompts.Stage) async {
        guard let d = doc(id) else { return }
        let autonomy = jobs[id]?.autonomy ?? .step
        switch stage {
        case .specify:
            if !d.openQuestions.isEmpty && autonomy == .step { return }       // wait for the answers
            if autonomy == .step { return }                                   // step by step: you start the next stage
            await run(id, .plan)
        case .plan:
            if autonomy == .step { return }
            await run(id, .tasks)
        case .tasks:
            if autonomy == .hands { await implementReady(id) } else if autonomy == .plan { jobs[id]?.gate = true }
        }
    }

    func answer(_ id: String, answers: String) async { await run(id, .specify, answers: answers) }

    // MARK: Building

    func startBuilding(_ id: String) async { jobs[id]?.gate = false; await implementReady(id) }

    /// Starts every task that can start now (up to two at a time), each on its own branch stacked on what it needs.
    func implementReady(_ id: String, limit: Int = 2) async {
        guard let d = doc(id) else { return }
        let running = taskSessions.filter { $0.key.hasPrefix(id + "/") }.compactMap { Workspace.shared.controller($0.value) }.filter { $0.isBusy }.count
        let ready = Specs.ready(d.tasks, merged: merged, coded: coded)
        for t in ready.prefix(max(0, limit - running)) { await implement(id, t, focus: false) }
    }

    func implement(_ id: String, _ task: SpecTask, focus: Bool = true) async {
        guard let r = repo, let d = doc(id), let text = d.tasksText else { return }
        let branch = Specs.taskBranch(spec: id, task: task)
        let parent = Specs.parentBranch(for: task, in: d.tasks, trunk: trunk, merged: merged)
        let prompt = SpecPrompts.implement(task: task, spec: d, constitution: constitution)
        do {
            let c = try await Workspace.shared.startTask(repo: r.dir, environment: r.environment, branch: branch, parent: parent,
                                                         title: "\(task.id) \(task.title)", prompt: prompt, focus: focus) { [weak self] session in
                Task { @MainActor in await self?.taskTurnEnded(id, task.id, session) }
            }
            taskSessions["\(id)/\(task.id)"] = c.id
            let updated = Specs.updateTask(text, id: task.id, branch: branch)
            try await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/tasks.md", updated, in: r.dir) }
            await refresh()
        } catch { jobs[id, default: Job()].error = AppModel.shared.capture(error, action: "Start \(task.id)") }
    }

    func taskTurnEnded(_ id: String, _ taskId: String, _ session: SessionController) async {
        await refresh()
        guard jobs[id]?.autonomy == .hands else { return }
        await implementReady(id)
        let d = doc(id)
        let all = d?.tasks ?? []
        let outstanding = all.filter { !$0.done && !($0.branch.map(merged.contains) ?? false) }
        let allCoded = outstanding.allSatisfy { $0.branch.map(coded.contains) ?? false }
        if allCoded, !outstanding.isEmpty, Specs.ready(all, merged: merged, coded: coded).isEmpty { await submitAndArm(id) }
    }

    /// Pushes the stack of this spec's branches, opens the pull requests, and lets the merge rules take it from there.
    func submitAndArm(_ id: String) async {
        guard let r = repo, jobs[id]?.submitting != true else { return }
        jobs[id, default: Job()].submitting = true
        jobs[id, default: Job()].submitNote = nil
        defer { jobs[id, default: Job()].submitting = false }
        let e = env
        do {
            let count = try await Exec.with(e) { () -> Int in
                let host = LiveStackHost(dir: r.dir)
                var count = 0
                for st in await Stacks.load(in: r.dir, host: host) where st.branches.contains(where: { $0.name.hasPrefix("spec-\(id.prefix(3))-") }) { count += try await Stacks.submit(st, in: r.dir, host: host).count }
                return count
            }
            StackCenter.shared.arm(repo: r)
            jobs[id, default: Job()].submitFailed = false
            jobs[id, default: Job()].submitNote = count == 0 ? "Nothing to submit yet. Auto-merge is on." : "Submitted \(count) pull request\(count == 1 ? "" : "s"). Auto-merge is on: they merge from the bottom when checks pass."
            AppModel.shared.notify("Pull requests are open for \(doc(id)?.title ?? id)", body: "They merge from the bottom when checks pass.")
            await refresh()
        } catch {
            jobs[id, default: Job()].submitFailed = true
            jobs[id, default: Job()].submitNote = AppModel.shared.capture(error, action: "Submit the stack")
        }
    }

    // MARK: Editing

    func save(_ id: String, file: String, text: String) async {
        guard let r = repo else { return }
        try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(file)", text, in: r.dir) }
        await refresh()
    }

    // MARK: Other ways in

    func fromSession(_ s: SessionController) {
        let digest = ContextDigest.build(items: s.items, budget: 7000)
        preset = SpecSource(label: "Session \"\(s.meta.title)\"", title: s.meta.title, requirement: "Turn the idea discussed in this conversation into a specification. Conversation summary:\n\n\(digest)")
        newWork = true
    }

    func codeSource(branch: String) async -> SpecSource? {
        guard let r = repo else { return nil }
        let t = trunk
        let (stat, diff) = await Exec.with(env) { () -> (String, String) in
            let st = (try? await Shell.check("git", ["diff", "--stat", "\(t)...\(branch)"], cwd: URL(fileURLWithPath: r.dir))) ?? ""
            let d = (try? await Shell.check("git", ["diff", "-U1", "\(t)...\(branch)"], cwd: URL(fileURLWithPath: r.dir))) ?? ""
            return (st, String(d.prefix(20000)))
        }
        guard !stat.isEmpty else { return nil }
        return SpecSource(label: "Branch \(branch)", title: branch, requirement: "Write the specification for this existing change, as if it were planned before the code: what problem it solves, the requirements it satisfies, and how to verify them. Describe behavior, not the diff.\n\nChange summary:\n\(stat)\n\nDiff:\n\(diff)")
    }

    /// Adopts a folder of spec documents from elsewhere, mapping common file names onto this layout.
    func importFolder(_ url: URL) async {
        guard let r = repo else { return }
        let map = ["spec.md": "spec.md", "requirements.md": "spec.md", "plan.md": "plan.md", "design.md": "plan.md", "tasks.md": "tasks.md"]
        var files: [String: String] = [:]
        for (src, dst) in map { if let t = try? String(contentsOf: url.appendingPathComponent(src), encoding: .utf8) { files[dst] = t } }
        guard let spec = files["spec.md"] else { AppModel.shared.show("No spec.md or requirements.md found in that folder.", error: true); return }
        let title = Specs.title(of: spec) ?? url.lastPathComponent
        let id = Specs.folderName(number: Specs.nextNumber(existing: docs.map(\.id)), title: title)
        for (name, text) in files { try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(name)", text, in: r.dir) } }
        await refresh(); selected = id
    }
}
