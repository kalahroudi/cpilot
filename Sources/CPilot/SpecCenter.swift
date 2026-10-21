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
    /// The repository on screen. Every repository has its own center, so a build in one carries on while you look at another.
    static var shared: SpecCenter { SpecHub.shared.shown }
    init(repo: PRCenter.Repo? = nil) { self.repo = repo }

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
        /// The stack was handed to auto-merge: nothing is left for CPilot to build in this spec.
        var handedOn = false
    }

    let repo: PRCenter.Repo?
    private var hub: SpecHub { SpecHub.shared }
    /// Repos whose specs are committed instead of hidden from git ("environment|folder"). Read each time: every center shares it.
    private static let trackedKey = "trackedSpecRepos"
    private func trackKey(_ r: PRCenter.Repo) -> String { "\(r.environment ?? "")|\(r.dir)" }
    var tracked: Bool { repo.map { Set(UserDefaults.standard.stringArray(forKey: Self.trackedKey) ?? []).contains(trackKey($0)) } ?? false }
    func setTracked(_ on: Bool) async {
        guard let r = repo else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.trackedKey) ?? [])
        if on { set.insert(trackKey(r)) } else { set.remove(trackKey(r)) }
        UserDefaults.standard.set(Array(set), forKey: Self.trackedKey)
        await Exec.with(env) { await Specs.setTracked(on, in: r.dir) }
    }
    var docs: [SpecDoc] = []
    var constitution: String?
    var selected: String?
    var jobs: [String: Job] = [:]
    private var scope: String { repo.map { RepoRef(dir: $0.dir, environment: $0.environment).key } ?? "" }
    private func change(_ id: String, _ f: (inout Job) -> Void) { if var j = jobs[id] { f(&j); jobs[id] = j } }
    private func create(_ id: String, _ f: (inout Job) -> Void) { var j = jobs[id] ?? Job(); f(&j); jobs[id] = j }

    /// Keeps where this spec stands on disk, so a restart carries on from here. Forgotten once there is nothing left to carry on or wait for.
    private func saveRun(_ id: String, attempts: Int? = nil) {
        guard let j = jobs[id] else { hub.runs.remove(id, in: scope); hub.save(); return }
        let e = SpecRunEntry(autonomy: j.handedOn ? Autonomy.step.rawValue : j.autonomy.rawValue, stage: j.running ? j.stage : nil,
                             draftStage: j.draft?.stage.rawValue, draftText: j.draft?.text, gate: j.gate,
                             attempts: attempts ?? hub.runs.entry(id, in: scope)?.attempts ?? 0)
        hub.runs.set(e, id, in: scope); hub.save()
        if e.handsOff { hub.keepWatching() }
    }
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
    private var resuming: Set<String> = []

    func doc(_ id: String?) -> SpecDoc? { docs.first { $0.id == id } }
    func status(_ d: SpecDoc) -> SpecDoc.Status { d.status(merged: merged, started: started) }

    // MARK: Loading

    /// Show this repository in the Specs pane.
    func open(_ r: PRCenter.Repo) async {
        let c = hub.show(r)
        Project.shared.current = r
        await c.load()
    }

    /// Reads the repository (when it has not been read lately), then carries on whatever was left half done.
    func load() async {
        if lastRefresh == nil { await refresh() } else { await refreshIfStale(manual: false) }
        await resumeRuns()
    }

    /// Carries on every spec of this repository that has something to carry on, from what was saved and what git and `tasks.md` say.
    func resumeRuns() async {
        for (id, _) in hub.runs.pending(in: scope) where resuming.insert(id).inserted {
            await resume(id)
            resuming.remove(id)
        }
    }

    private func dropRun(_ id: String) { hub.runs.remove(id, in: scope); hub.save() }

    private func resume(_ id: String) async {
        guard let e = hub.runs.entry(id, in: scope) else { return }
        if jobs[id]?.running == true || jobs[id]?.submitting == true { return }
        create(id) { j in
            j.autonomy = Autonomy(rawValue: e.autonomy) ?? .step; j.gate = e.gate
            if j.draft == nil, let ds = e.draftStage, let st = SpecPrompts.Stage(rawValue: ds), let t = e.draftText { j.draft = Draft(stage: st, text: t) }
        }
        let d = doc(id)
        switch SpecResume.decide(e, docExists: d != nil, hasSpec: d?.spec != nil, hasDraft: jobs[id]?.draft != nil) {
        case .drop: dropRun(id)
        case .settle: saveRun(id)
        case .rewrite(let stage, let attempts):
            guard let st = SpecPrompts.Stage(rawValue: stage) else { dropRun(id); return }
            saveRun(id, attempts: attempts)
            await run(id, st)
        case .giveUp(let stage, let attempts):
            let message = "The \(stage) could not be written after \(attempts) tries."
            change(id) { $0.error = message }; saveRun(id, attempts: 0)
            AppModel.shared.notify("\(d?.title ?? id): \(message)", body: "Open the spec to try again.")
        case .review:
            if let draft = jobs[id]?.draft, shouldAutoApprove(id, draft.stage, draft.text) { await approve(id, text: draft.text) }   // otherwise it waits for you
        case .wait: break
        case .build: if jobs[id]?.handedOn != true { await build(id) }
        }
    }

    /// The hands-off build of one spec, from wherever it stands: missing stages are written, tasks that were started are picked up again,
    /// ready tasks start, and a finished stack is submitted.
    private func build(_ id: String) async {
        guard let d = doc(id), d.spec != nil else { dropRun(id); return }      // the spec was never approved: nothing to build
        if d.plan == nil { await run(id, .plan); return }
        if d.tasks.isEmpty { await run(id, .tasks); return }
        reattachTasks(id, d)
        await continueBuilding(id)
    }

    /// Called now and then by the hub for hands-off builds that have gone quiet: if no task is working and nothing is ready or submitted, look again.
    func watchdog() async {
        for (id, e) in hub.runs.pending(in: scope) where e.handsOff && resuming.insert(id).inserted {
            defer { resuming.remove(id) }
            guard let j = jobs[id], !j.running, !j.submitting, !j.handedOn, j.draft == nil, !j.gate else { continue }
            if taskSessions.filter({ $0.key.hasPrefix(id + "/") }).compactMap({ Workspace.shared.controller($0.value) }).contains(where: \.isBusy) { continue }
            await build(id)
        }
    }

    /// Task sessions started before a restart: listen for their turns again, and nudge the ones that stopped before writing any code.
    private func reattachTasks(_ id: String, _ d: SpecDoc) {
        guard let r = repo else { return }
        for t in d.tasks where !t.done {
            guard let branch = t.branch, !merged.contains(branch),
                  let meta = Workspace.shared.session(forBranch: branch, repo: r.dir, environment: r.environment),
                  let c = Workspace.shared.controller(meta.id) else { continue }
            taskSessions["\(id)/\(t.id)"] = c.id
            c.onTurnEnd = turnHandler(id, t.id)
            if !coded.contains(branch), !c.isBusy {
                c.loadIfNeeded()
                c.draft = "CPilot was restarted while you worked on \(t.id) \(t.title). Carry on from where you stopped and finish the task."
                c.send()
            }
        }
    }

    private func turnHandler(_ id: String, _ taskId: String) -> (SessionController) -> Void {
        { [weak self] session in Task { @MainActor in await self?.taskTurnEnded(id, taskId, session) } }
    }

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
        let landed = await Exec.with(e) { (try? await GitHub.list(in: r.dir, state: "merged")) ?? [] }
        for d in docs { await tickMerged(d, landed: landed) }
        if selected == nil { selected = docs.last?.id }
    }

    private func tickMerged(_ d: SpecDoc, landed: [PullRequest]) async {
        guard let r = repo, var text = d.tasksText else { return }
        var changed = false
        for t in d.tasks where !t.done && ((t.branch.map(merged.contains) ?? false) || landed.contains { Specs.isMergedWork(task: t, spec: d.id, head: $0.headRefName, title: $0.title) }) { text = Specs.updateTask(text, id: t.id, done: true); changed = true }
        guard changed else { return }
        try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(d.id)/tasks.md", text, in: r.dir, tracked: tracked) }
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
                if constitution == nil { try await Specs.write("\(Specs.folder)/constitution.md", Specs.defaultConstitution, in: r.dir, tracked: tracked) }
                try await Specs.write("\(Specs.folder)/\(id)/source.md", "> Source: \(source.label)\n\n\(source.requirement)\n", in: r.dir, tracked: tracked)
            }
        } catch { AppModel.shared.failQuietly(error, action: "Create the spec"); return }
        if allowGit, autonomy == .hands { Workspace.shared.allowCommands(["git add", "git commit", "git status", "git diff"], for: r.dir) }
        await refresh()
        selected = id
        jobs[id] = Job(autonomy: autonomy)
        saveRun(id)
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
        create(id) { $0.running = true; $0.stage = stage.rawValue; $0.status = "Starting…"; $0.error = nil; $0.draft = nil; $0.gate = false }
        saveRun(id)
        let d = doc(id)
        let autonomy = jobs[id]?.autonomy ?? .step
        let assume = autonomy != .step
        let prompt: String
        switch stage {
        case .specify:
            var req = requirement ?? ""
            if requirement == nil { req = (await self.requirement(for: id, fallback: nil)).text }
            prompt = SpecPrompts.specify(requirement: req, source: label ?? "Described by you", constitution: constitution, answers: answers, previous: answers == nil ? nil : d?.spec, assume: assume)
        case .plan: prompt = SpecPrompts.plan(spec: d?.spec ?? "", constitution: constitution)
        case .tasks: prompt = SpecPrompts.tasks(spec: d?.spec ?? "", plan: d?.plan ?? "", constitution: constitution)
        }
        // Nobody is watching a plan-for-me or hands-off run, so a stage that fails is tried again before it is reported.
        let retries = autonomy == .step ? 0 : 2
        var attempt = 0
        while true {
            do {
                let reply = try await SpecStageRunner.run(prompt: prompt, cwd: r.dir, environment: env, images: images) { [weak self] p in Task { @MainActor in self?.change(id) { $0.status = p } } }
                let text = SpecPrompts.extractDocument(reply)
                if stage == .tasks, Specs.parseTasks(text).isEmpty { throw SpecStageError.failed("The agent did not write any tasks in the expected format. Try again.") }
                if stage == .specify, Specs.title(of: text) == nil { throw SpecStageError.failed("The agent did not write a spec. Try again.") }
                change(id) { $0.running = false; $0.status = ""; $0.draft = Draft(stage: stage, text: text) }
                saveRun(id, attempts: 0)
                if shouldAutoApprove(id, stage, text) { await approve(id, text: text) }
                return
            } catch {
                if attempt < retries, !Task.isCancelled {
                    attempt += 1
                    change(id) { $0.status = "Trying again (\(attempt) of \(retries))…" }
                    try? await Task.sleep(for: .seconds(attempt == 1 ? 5 : 20))
                    continue
                }
                let message = AppModel.shared.capture(error, action: "Write the \(stage.rawValue)")
                change(id) { $0.running = false; $0.error = message }
                saveRun(id)
                if autonomy != .step { AppModel.shared.notify("\(d?.title ?? id): the \(stage.rawValue) could not be written", body: message) }
                return
            }
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
        do { try await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(file)", text, in: r.dir, tracked: tracked) } }
        catch { let message = AppModel.shared.capture(error, action: "Save the \(file)"); change(id) { $0.error = message }; saveRun(id); return }
        change(id) { $0.draft = nil }
        saveRun(id)
        await refresh()
        await advance(id, after: draft.stage)
    }

    func discard(_ id: String) { change(id) { $0.draft = nil }; saveRun(id) }

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
            if autonomy == .hands { await implementReady(id) } else if autonomy == .plan { change(id) { $0.gate = true }; saveRun(id) }
        }
    }

    func answer(_ id: String, answers: String) async { await run(id, .specify, answers: answers) }

    // MARK: Building

    func startBuilding(_ id: String) async { change(id) { $0.gate = false }; saveRun(id); await implementReady(id) }

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
                                                         title: "\(task.id) \(task.title)", prompt: prompt, focus: focus, onTurnEnd: turnHandler(id, task.id))
            taskSessions["\(id)/\(task.id)"] = c.id
            let updated = Specs.updateTask(text, id: task.id, branch: branch)
            try await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/tasks.md", updated, in: r.dir, tracked: tracked) }
            await refresh()
        } catch { let message = AppModel.shared.capture(error, action: "Start \(task.id)"); create(id) { $0.error = message } }
    }

    /// A task's turn ended: start what that unlocks, or submit the stack when every task has code. Runs whichever repository is on screen.
    func taskTurnEnded(_ id: String, _ taskId: String, _ session: SessionController) async {
        await continueBuilding(id)
    }

    private func continueBuilding(_ id: String) async {
        await refresh()
        guard jobs[id]?.autonomy == .hands, jobs[id]?.handedOn != true else { return }
        await implementReady(id)
        let d = doc(id)
        let all = d?.tasks ?? []
        let outstanding = all.filter { !$0.done && !($0.branch.map(merged.contains) ?? false) }
        if outstanding.isEmpty, !all.isEmpty { change(id) { $0.handedOn = true }; dropRun(id); return }   // everything merged: nothing left to carry on
        let allCoded = outstanding.allSatisfy { $0.branch.map(coded.contains) ?? false }
        if allCoded, !outstanding.isEmpty, Specs.ready(all, merged: merged, coded: coded).isEmpty { await submitAndArm(id) }
    }

    /// Pushes the stack of this spec's branches, opens the pull requests, and lets the merge rules take it from there.
    func submitAndArm(_ id: String) async {
        guard let r = repo, jobs[id]?.submitting != true else { return }
        create(id) { $0.submitting = true; $0.submitNote = nil }
        defer { create(id) { $0.submitting = false } }
        let e = env
        do {
            let count = try await Exec.with(e) { () -> Int in
                let host = LiveStackHost(dir: r.dir)
                var count = 0
                for st in await Stacks.load(in: r.dir, host: host) where st.branches.contains(where: { $0.name.hasPrefix("spec-\(id.prefix(3))-") }) { count += try await Stacks.submit(st, in: r.dir, host: host).count }
                return count
            }
            StackCenter.shared.arm(repo: r)
            create(id) { $0.handedOn = true; $0.submitFailed = false; $0.submitNote = count == 0 ? "Nothing to submit yet. Auto-merge is on." : "Submitted \(count) pull request\(count == 1 ? "" : "s"). Auto-merge is on: they merge from the bottom when checks pass." }
            dropRun(id)
            AppModel.shared.notify("Pull requests are open for \(doc(id)?.title ?? id)", body: "They merge from the bottom when checks pass.")
            await refresh()
        } catch {
            let message = AppModel.shared.capture(error, action: "Submit the stack")
            create(id) { $0.submitFailed = true; $0.submitNote = message }
        }
    }

    // MARK: Editing

    func save(_ id: String, file: String, text: String) async {
        guard let r = repo else { return }
        try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(file)", text, in: r.dir, tracked: tracked) }
        await refresh()
    }

    /// Deletes a spec that has not been built: its folder and anything saved about its run.
    func delete(_ id: String) async {
        guard let r = repo, jobs[id]?.running != true else { return }
        do { try await Exec.with(env) { try await Specs.remove(id, in: r.dir) } } catch { jobs[id, default: Job()].error = "\(error)"; return }
        jobs[id] = nil; dropRun(id)
        if selected == id { selected = nil }
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
        for (name, text) in files { try? await Exec.with(env) { try await Specs.write("\(Specs.folder)/\(id)/\(name)", text, in: r.dir, tracked: tracked) } }
        await refresh(); selected = id
    }
}

/// Every repository has its own `SpecCenter`; the hub holds them, says which one the Specs pane shows, and keeps the hands-off builds going
/// on disk and in time: they are picked up again at launch, and looked at every few minutes in case a task finished while nobody listened.
@MainActor @Observable
final class SpecHub {
    static let shared = SpecHub()
    var shown = SpecCenter()
    @ObservationIgnored private var centers: [String: SpecCenter] = [:]
    @ObservationIgnored var runs = SpecRunState.load(from: SpecHub.url)
    @ObservationIgnored private var watching: Task<Void, Never>?
    private static let url = AppPaths().root.appendingPathComponent("spec-runs.json")

    func save() { runs.save(to: Self.url) }

    func center(for r: PRCenter.Repo) -> SpecCenter {
        let key = RepoRef(dir: r.dir, environment: r.environment).key
        if let c = centers[key] { return c }
        let c = SpecCenter(repo: r); centers[key] = c; return c
    }

    @discardableResult func show(_ r: PRCenter.Repo) -> SpecCenter { let c = center(for: r); if shown !== c { shown = c }; return c }

    /// At launch: every repository with a spec to carry on is read and carried on, whether or not you ever open Specs.
    func resumeAll() async {
        guard !AppModel.shared.demo else { return }
        await withTaskGroup(of: Void.self) { group in
            for key in runs.scopes {
                guard let ref = RepoRef(key: key) else { continue }
                let c = center(for: PRCenter.Repo(dir: ref.dir, environment: ref.environment))
                group.addTask { await c.load() }
            }
        }
        keepWatching()
    }

    /// While any spec builds hands-off, look at it every three minutes. Costs nothing when none does.
    func keepWatching() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard let self else { return }
                let keys = self.runs.scopes.filter { k in self.runs.pending(in: k).contains { $0.entry.handsOff } }
                if keys.isEmpty { self.watching = nil; return }
                for k in keys { await self.centers[k]?.watchdog() }
            }
        }
    }
}
