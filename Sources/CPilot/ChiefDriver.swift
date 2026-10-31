// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// What the chief pilot's tools do inside the app. Each call names a chief session; the repository is always that session's own,
/// whatever the call says. Pushing and merging ask the user first.
@MainActor
enum ChiefDriver {
    typealias Approve = (_ title: String, _ detail: String) async -> Bool
    typealias Reply = (Int, [String: Any])

    private static func fail(_ message: String, _ code: Int = 400) -> Reply { (code, ["error": message]) }

    static func handle(_ path: String, _ body: [String: Any], approve: Approve) async -> Reply {
        guard let action = ChiefPilot.Action(rawValue: String(path.dropFirst("/v1/chief/".count))) else { return fail("Unknown action.") }
        guard let sid = body["session_id"] as? String, let session = Workspace.shared.controller(sid), session.meta.chief == true, session.meta.environment == nil else {
            return fail("Only a chief pilot session can do this.", 403)
        }
        let repo = PRCenter.Repo(dir: session.meta.cwd, environment: nil)
        let specs = SpecHub.shared.center(for: repo)
        func text(_ k: String) -> String? { (body[k] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        if action.rawValue.hasPrefix("spec") || action == .taskStart, specs.lastRefresh == nil { await specs.refresh() }

        switch action {
        case .specCreate:
            guard let title = text("title"), let requirement = text("requirement") else { return fail("title and requirement are required.") }
            let source = SpecSource(label: "Chief pilot", title: title, requirement: requirement)
            guard let id = await specs.begin(source, autonomy: .step) else { return fail("Could not create the spec.") }
            writing(specs, id, .specify)
            Task { await specs.run(id, .specify, requirement: requirement, label: source.label) }
            return (200, ["id": id, "status": "Writing the spec. Call spec_job until running is false, then read the draft."])

        case .specStage:
            guard let id = text("id"), let d = specs.doc(id) else { return fail("No such spec.") }
            guard let stage = text("stage").flatMap(SpecPrompts.Stage.init(rawValue:)) else { return fail("stage must be specify, plan or tasks.") }
            if specs.jobs[id]?.running == true { return fail("A stage is already being written for this spec.") }
            if stage == .plan, d.spec == nil { return fail("Approve the spec first.") }
            if stage == .tasks, d.plan == nil { return fail("Approve the plan first.") }
            writing(specs, id, stage)
            let answers = text("answers")
            Task { if stage == .specify, let answers { await specs.answer(id, answers: answers) } else { await specs.run(id, stage) } }
            return (200, ["id": id, "status": "Writing the \(stage.rawValue). Call spec_job until running is false, then read the draft."])

        case .specJob:
            guard let id = text("id"), specs.doc(id) != nil else { return fail("No such spec.") }
            await wait(body) { specs.jobs[id]?.running != true }
            return (200, job(specs, specs.doc(id)!))

        case .specApprove:
            guard let id = text("id"), let d = specs.doc(id) else { return fail("No such spec.") }
            guard let draft = specs.jobs[id]?.draft else { return fail("There is no draft waiting. Run a stage with spec_stage first.") }
            let final = text("text") ?? draft.text
            let open = draft.stage == .specify ? Specs.openQuestions(final) : []
            if !open.isEmpty, body["accept_open_questions"] as? Bool != true {
                return fail("The spec still has open questions:\n- " + open.joined(separator: "\n- ") + "\nAsk the user, then run spec_stage with `answers`. If the user told you to decide for them, call spec_approve again with accept_open_questions: true.")
            }
            await specs.approve(id, text: final)
            var out = job(specs, specs.doc(id) ?? d)
            out["saved"] = draft.stage.rawValue
            return (200, out)

        case .taskStart:
            guard let id = text("id"), specs.doc(id)?.tasksText != nil else { return fail("No such spec, or it has no tasks yet.") }
            await specs.refresh()
            guard let d = specs.doc(id) else { return fail("No such spec.") }
            let before = Specs.ready(d.tasks, merged: specs.merged, coded: specs.coded)
            if let want = text("task") {
                guard let t = before.first(where: { $0.id == want }) else { return fail("\(want) is not ready: it is finished, already started, or waits for a task that has no code yet.") }
                await specs.implement(id, t, focus: false)
            } else {
                if before.isEmpty { return (200, ["started": [String](), "note": "Nothing is ready. Tasks wait for the ones they need."]) }
                await specs.implementReady(id)
            }
            if let e = specs.jobs[id]?.error { return fail(e) }
            let after = Set(Specs.ready(specs.doc(id)?.tasks ?? [], merged: specs.merged, coded: specs.coded).map(\.id))
            return (200, ["started": before.map(\.id).filter { !after.contains($0) }, "sessions": "Watch them with list_sessions and get_session."])

        case .prReview:
            guard let n = body["pr"] as? Int else { return fail("pr (the pull request number) is required.") }
            guard let pr = try? await GitHub.view(n, in: repo.dir), pr.isOpen else { return fail("#\(n) is not an open pull request of this repository.") }
            if let m = reviewer(of: n, in: repo), Workspace.shared.controller(m.id)?.isBusy == true { return fail("#\(n) already has a reviewer working on it.") }
            do {
                let c = try await PRCenter.shared.startSession(on: pr, dir: repo.dir, prompt: ChiefPilot.reviewPrompt(number: n, title: pr.title, head: pr.headRefName, base: pr.baseRefName),
                                                               title: "Review #\(n)", readOnly: false, show: false, reviewOf: n)
                return (200, ["session_id": c.id, "status": "A reviewer is working on #\(n). Call pr_reviews with wait_seconds to follow it."])
            } catch { return fail("Could not start the reviewer: \(error.localizedDescription)") }

        case .prReviews:
            await wait(body) { !Workspace.shared.sessions.filter { $0.reviewOf != nil && $0.cwd == repo.dir }.contains { Workspace.shared.controller($0.id)?.isBusy == true } }
            let open = (try? await GitHub.list(in: repo.dir)) ?? []
            return (200, ["pullRequests": open.map { pr -> [String: Any] in
                var r: [String: Any] = ["pr": pr.number, "title": pr.title, "branch": pr.headRefName]
                guard let m = reviewer(of: pr.number, in: repo) else { r["reviewer"] = "none"; return r }
                r["session_id"] = m.id
                r["reviewer"] = reviewState(m)
                if let last = Workspace.shared.store.items(m.id, limit: 40).last(where: { $0.kind == .assistant && $0.status == .done }) { r["report"] = String(last.text.prefix(1500)) }
                return r
            }])

        case .stackRestack, .stackSubmit, .prMerge:
            return await stackAction(action, body, repo: repo, approve: approve)
        }
    }

    /// Waits up to `wait_seconds` (at most 90) for `done`, so the chief pilot does not have to poll.
    private static func wait(_ body: [String: Any], until done: () -> Bool) async {
        let limit = min(max((body["wait_seconds"] as? Int) ?? 0, 0), 90)
        var waited = 0
        while waited < limit, !done() { try? await Task.sleep(for: .seconds(2)); waited += 2 }
    }

    /// The newest reviewer session assigned to a pull request.
    private static func reviewer(of n: Int, in repo: PRCenter.Repo) -> SessionMeta? {
        Workspace.shared.sessions.filter { $0.reviewOf == n && $0.cwd == repo.dir }.max { $0.updatedAt < $1.updatedAt }
    }

    private static func reviewState(_ m: SessionMeta) -> String {
        guard let c = Workspace.shared.controller(m.id) else { return "done" }
        if case .failed(let why) = c.state { return "failed: \(why)" }
        return c.isBusy ? "working" : "done"
    }

    /// A pull request merges only after its reviewer has finished. Nil means it may go ahead.
    private static func reviewProblem(_ n: Int, in repo: PRCenter.Repo) -> String? {
        guard let m = reviewer(of: n, in: repo) else { return "#\(n) has no reviewer. Assign one with pr_review {pr: \(n)} and wait for it to finish." }
        switch reviewState(m) {
        case "working": return "#\(n)'s reviewer is still working. Wait with pr_reviews and wait_seconds."
        case "done": return nil
        default: return "#\(n)'s reviewer \(reviewState(m)). Read its session, then assign another with pr_review."
        }
    }

    /// Marks the stage as running at once, so a status call made straight after the request does not see an idle spec.
    private static func writing(_ c: SpecCenter, _ id: String, _ stage: SpecPrompts.Stage) {
        var j = c.jobs[id] ?? SpecCenter.Job()
        j.running = true; j.stage = stage.rawValue; j.status = "Starting…"; j.error = nil
        c.jobs[id] = j
    }

    private static func job(_ c: SpecCenter, _ d: SpecDoc) -> [String: Any] {
        let j = c.jobs[d.id]
        let ready = Set(Specs.ready(d.tasks, merged: c.merged, coded: c.coded).map(\.id))
        var out: [String: Any] = [
            "id": d.id, "title": d.title, "status": c.status(d).label, "running": j?.running ?? false,
            "stage": j?.stage ?? "", "progress": j?.status ?? "",
            "documents": ["spec": d.spec != nil, "plan": d.plan != nil, "tasks": d.tasksText != nil],
            "openQuestions": d.openQuestions,
            "tasks": d.tasks.map { t -> [String: Any] in
                var r: [String: Any] = ["id": t.id, "title": t.title, "done": t.done, "ready": ready.contains(t.id), "needs": t.needs]
                if let b = t.branch { r["branch"] = b }
                if let p = t.pr { r["pr"] = p }
                return r
            },
        ]
        if let e = j?.error { out["error"] = e }
        if let draft = j?.draft { out["draft"] = ["stage": draft.stage.rawValue, "text": String(draft.text.prefix(12000))] }
        return out
    }

    private static func stackAction(_ action: ChiefPilot.Action, _ body: [String: Any], repo: PRCenter.Repo, approve: Approve) async -> Reply {
        let sc = StackCenter.shared
        guard sc.busy == nil else { return fail("Another stack operation is running (\(sc.busy ?? "")). Try again in a moment.") }
        await sc.open(repo, force: true)
        let open = sc.stacks.filter { $0.branches.contains { !$0.isMerged } }
        let wanted = (body["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let stack: Stack
        if let wanted {
            guard let s = open.first(where: { $0.branches.contains { $0.name == wanted } }) else { return fail("No open stack contains \(wanted).") }
            stack = s
        } else if open.count == 1 {
            stack = open[0]
        } else {
            return fail(open.isEmpty ? "There are no stacked branches yet. Start tasks with task_start." : "There is more than one stack. Pass `branch` with a branch of the one you mean: " + open.map { $0.branches.first(where: { !$0.isMerged })?.name ?? $0.id }.joined(separator: ", ") + ".")
        }
        let name = URL(fileURLWithPath: repo.dir).lastPathComponent
        switch action {
        case .stackRestack:
            await sc.restack(stack)
        case .stackSubmit:
            let names = stack.branches.filter { !$0.isMerged }.map(\.name)
            guard await approve("The chief pilot wants to push and open pull requests", "Repository: \(name)\nBranches: \(names.joined(separator: ", "))\nThis force-pushes with a lease and opens or updates one pull request per branch.") else { return fail("The user declined.", 403) }
            await sc.submit(stack)
        default:
            guard let bottom = stack.bottomOpen, let n = bottom.pr else { return fail("Nothing is open to merge. Submit the stack first.") }
            if let problem = reviewProblem(n, in: repo) { return fail(problem) }
            guard await approve("The chief pilot wants to merge a pull request", "Repository: \(name)\n#\(n) \(bottom.title ?? bottom.name) into \(stack.trunk)\nIt is merged only if its checks pass and the merge rules allow it.") else { return fail("The user declined.", 403) }
            await sc.mergeBottom(stack)
        }
        if let e = sc.error {
            // The sentence on the card is deliberately vague; the chief pilot needs the cause to decide what to do.
            let cause = AppModel.shared.report(forMessage: e)?.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return fail(cause.map { "\(e)\n\($0.prefix(1200))" } ?? e)
        }
        return (200, ["ok": true, "note": sc.notice ?? "Done."])
    }
}
