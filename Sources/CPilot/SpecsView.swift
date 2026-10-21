// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

struct SpecsView: View {
    let center = SpecCenter.shared
    let pr = PRCenter.shared
    @State private var mode = 0                 // 0 specs, 1 issues
    @State private var query = ""

    var body: some View {
        @Bindable var c = center
        VStack(spacing: 0) {
            PaneHeader(title: "Specs", subtitle: center.repo?.name ?? "From an idea to a stack of pull requests") {
                HStack(spacing: 8) {
                    RepoMenu()
                    if center.repo != nil {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text(center.loading ? "Refreshing…" : center.lastRefresh.map { "Updated \($0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))" } ?? "")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    AsyncButton { await center.refreshIfStale(manual: true) } label: {
                        if center.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.soft).disabled(center.loading).help(center.fresh ? "Refreshed recently; wait a minute to avoid GitHub rate limits" : "Refresh").accessibilityLabel("Refresh")
                    Button("New work") { center.preset = nil; center.newWork = true }.buttonStyle(Pill(kind: .primary)).disabled(center.repo == nil)
                }
            }
            if center.repo == nil {
                VStack(spacing: 8) {
                    Text("Choose a repository").font(.system(size: 15, weight: .semibold))
                    if let first = pr.repos().first { AsyncButton("Open \(first.name)") { await center.open(first) }.buttonStyle(Pill(kind: .primary)) }
                    else { Text("Start a session in a project first.").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        Segmented(options: [(0, "Specs"), (1, "Issues")], selection: $mode).padding(10)
                        if mode == 0 { SpecList() } else { IssueList(query: $query) }
                    }.frame(minWidth: 240, idealWidth: 270, maxWidth: 340).background(Theme.sidebar.opacity(0.4))
                    Group {
                        if let d = center.doc(center.selected) { SpecDetail(doc: d) }
                        else { VStack(spacing: 8) { Text(center.docs.isEmpty ? "No specs yet" : "Select a spec").font(.system(size: 15, weight: .semibold)); if center.docs.isEmpty { Text("Start from an issue, a rough requirement, a conversation or existing code.").font(.system(size: 12.5)).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.frame(minWidth: 460)
                }
            }
        }
        .background(Theme.pane)
        .onAppear {
            if AppModel.shared.demo { return }
            Project.shared.ensureDefault()
            if let r = Project.shared.current, r != center.repo { Task { await center.open(r) } } else { Task { await center.refreshIfStale(manual: false) } }
        }
        .onChange(of: Project.shared.current) { _, r in if !AppModel.shared.demo, let r, r != center.repo { Task { await center.open(r) } } }
        .sheet(isPresented: $c.newWork) { NewWorkSheet() }
    }
}

struct SpecList: View {
    let center = SpecCenter.shared
    var body: some View {
        let groups: [(String, [SpecDoc.Status])] = [("In progress", [.inProgress]), ("Ready to build", [.ready]), ("Planned", [.planned]), ("Draft", [.draft]), ("Done", [.done])]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.0) { name, statuses in
                    let list = center.docs.filter { statuses.contains(center.status($0)) }
                    if !list.isEmpty {
                        SectionLabel(name).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                        ForEach(list) { d in
                            Button { center.selected = d.id } label: {
                                HStack(spacing: 8) {
                                    if center.jobs[d.id]?.running == true { ProgressView().controlSize(.mini) }
                                    Text("\(String(format: "%03d", d.number)) \(d.title)").font(.system(size: 12.5, weight: center.selected == d.id ? .semibold : .regular)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if d.progress.total > 0 { ProgressRing(done: d.progress.done, total: d.progress.total) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(center.selected == d.id ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(center.selected == d.id ? Theme.accent : Color.primary).contentShape(Rectangle())
                            }.buttonStyle(.soft)
                        }
                    }
                }
            }.padding(.horizontal, 6).padding(.bottom, 10)
        }
    }
}

struct ProgressRing: View {
    let done: Int, total: Int
    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) { Capsule().fill(Theme.fill); Capsule().fill(Theme.ok).frame(width: 34 * CGFloat(done) / CGFloat(max(total, 1))) }.frame(width: 34, height: 5)
            Text("\(done)/\(total)").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

struct IssueList: View {
    let center = SpecCenter.shared
    @Binding var query: String
    var body: some View {
        VStack(spacing: 0) {
            SearchBox(prompt: "Search issues", text: $query).padding(.horizontal, 10).padding(.bottom, 8).onSubmit { Task { await center.loadIssues(search: query) } }
            if center.issuesLoading { ProgressView().controlSize(.small).padding() }
            if let e = center.issueError { ErrorLine(text: e).padding(10) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(center.issues) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("#\(i.number) \(i.title)").font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                            HStack(spacing: 4) { ForEach((i.labels ?? []).prefix(3), id: \.name) { Badge(text: $0.name) }; Spacer()
                                AsyncButton("Create spec") { await createSpec(i) }.buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                        }.padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().opacity(0.5)
                    }
                    if center.issues.isEmpty && !center.issuesLoading { Text("No open issues.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(14) }
                }
            }
        }.task { if center.issues.isEmpty { await center.loadIssues() } }
    }

    private func createSpec(_ i: GitHub.Issue) async {
        guard let r = center.repo else { return }
        let full = (try? await Exec.with(center.env) { try await GitHub.issue(i.number, in: r.dir) }) ?? i
        await center.start(SpecSource(label: "Issue #\(i.number)", title: i.title, requirement: full.requirementText()), autonomy: Autonomy(rawValue: Prefs.shared.specAutonomy) ?? .step)
    }
}

struct SpecDetail: View {
    let doc: SpecDoc
    let center = SpecCenter.shared
    @State private var editing: (file: String, text: String)?
    @State private var answers = ""

    private var job: SpecCenter.Job { center.jobs[doc.id] ?? SpecCenter.Job() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                pipeline
                jobView
                if !doc.openQuestions.isEmpty && job.draft == nil { questions }
                nextStep
                docs
                if !doc.tasks.isEmpty { tasks }
            }.padding(20).frame(maxWidth: 900, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let e = editing { DocEditor(title: e.file, text: e.text) { t in Task { await center.save(doc.id, file: e.file, text: t) } } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(doc.title).font(.system(size: 18, weight: .semibold))
            Badge(text: center.status(doc).label, kind: center.status(doc) == .done ? .ok : center.status(doc) == .inProgress ? .accent : .neutral)
            if let s = doc.source { Badge(text: s) }
            Spacer()
            Button("Open folder") { if let r = center.repo, center.env == nil { NSWorkspace.shared.open(URL(fileURLWithPath: r.dir + "/specs/" + doc.id)) } }.buttonStyle(Pill(kind: .plain)).disabled(center.env != nil)
        }
    }

    private var pipeline: some View {
        let t = doc.tasks, p = doc.progress
        return FlowLayout(spacing: 6) {
            step("Source", true)
            step("Spec", doc.spec != nil)
            if !doc.openQuestions.isEmpty { step("\(doc.openQuestions.count) questions", false, current: true) }
            step("Plan", doc.plan != nil)
            step("Tasks", !t.isEmpty)
            step(t.isEmpty ? "Build" : "Build \(p.done) of \(p.total)", !t.isEmpty && p.done == p.total, current: center.status(doc) == .inProgress)
        }
    }

    private func step(_ t: String, _ done: Bool, current: Bool = false) -> some View {
        HStack(spacing: 5) { Image(systemName: done ? "checkmark.circle.fill" : current ? "circle.dotted" : "circle").font(.system(size: 11)); Text(t).font(.system(size: 12)) }
            .padding(.horizontal, 9).padding(.vertical, 3).foregroundStyle(done ? Theme.ok : current ? Theme.accent : .secondary)
            .background(current ? Theme.accentSoft : Theme.fill, in: Capsule())
    }

    @ViewBuilder private var jobView: some View {
        if job.running {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing the \(job.stage)…").font(.system(size: 13, weight: .medium)); Text(job.status).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
        if let e = job.error {
            VStack(alignment: .leading, spacing: 8) {
                Label { ErrorLine(text: e) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger) }
                AsyncButton("Try again") { await center.run(doc.id, SpecPrompts.Stage(rawValue: job.stage) ?? .specify) }.buttonStyle(Pill(kind: .plain))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 10))
        }
        if let d = job.draft { DraftCard(doc: doc, draft: d) }
        if job.gate {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text("The spec, plan and tasks are written").font(.system(size: 13, weight: .semibold)); Text("Read them below. When you are happy, start building.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                AsyncButton("Start building") { await center.startBuilding(doc.id) }.buttonStyle(Pill(kind: .primary))
            }.padding(12).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Questions before the plan").font(.system(size: 13, weight: .semibold))
            ForEach(Array(doc.openQuestions.enumerated()), id: \.offset) { i, q in Text("\(i + 1). \(q)").font(.system(size: 12.5)) }
            TextEditor(text: $answers).font(.system(size: 12.5)).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Text("Answer in your own words, in any order.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack { Button("Update the spec with my answers") { let a = answers; answers = ""; Task { await center.answer(doc.id, answers: a) } }.buttonStyle(Pill(kind: .primary)).disabled(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || job.running)
                AsyncButton("Let the agent decide") { await center.answer(doc.id, answers: "Decide sensibly for every open question, and list your decisions under Assumptions.") }.buttonStyle(Pill(kind: .plain)).disabled(job.running) }
        }.card(padding: 14)
    }

    @ViewBuilder private var nextStep: some View {
        if !job.running, job.draft == nil, !job.gate, doc.openQuestions.isEmpty {
            if doc.spec != nil && doc.plan == nil { HStack { Text("Next: write the plan from the spec.").font(.system(size: 12.5)).foregroundStyle(.secondary); Spacer(); AsyncButton("Write the plan") { await center.run(doc.id, .plan) }.buttonStyle(Pill(kind: .primary)) }.card(padding: 12) }
            else if doc.plan != nil && doc.tasks.isEmpty { HStack { Text("Next: break the plan into tasks.").font(.system(size: 12.5)).foregroundStyle(.secondary); Spacer(); AsyncButton("Write the tasks") { await center.run(doc.id, .tasks) }.buttonStyle(Pill(kind: .primary)) }.card(padding: 12) }
            else if doc.spec == nil { HStack { Text("The spec has not been written yet.").font(.system(size: 12.5)).foregroundStyle(.secondary); Spacer(); AsyncButton("Write the spec") { await center.run(doc.id, .specify) }.buttonStyle(Pill(kind: .primary)) }.card(padding: 12) }
        }
    }

    private var docs: some View {
        HStack(alignment: .top, spacing: 12) {
            docCard("spec.md", "What and why. Requirements and checks.", doc.spec)
            docCard("plan.md", "How: components, data flow, risks, tests.", doc.plan)
            docCard("tasks.md", "Small tasks, one pull request each.", doc.tasksText)
        }
    }

    private func docCard(_ file: String, _ blurb: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(file).font(.system(size: 13, weight: .semibold, design: .monospaced)); Spacer(); Badge(text: text == nil ? "Missing" : "Written", kind: text == nil ? .neutral : .ok) }
            Text(blurb).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(text == nil ? "Write by hand" : "Read and edit") { editing = (file, text ?? "# \(doc.title)\n") }.buttonStyle(Pill(kind: .plain)).padding(.top, 4)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var tasks: some View {
        let ready = Specs.ready(doc.tasks, merged: center.merged, coded: center.coded)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks").font(.system(size: 13, weight: .semibold))
                Spacer()
                AsyncButton("Run all ready") { await center.implementReady(doc.id, limit: 4) }.buttonStyle(Pill(kind: .plain)).disabled(ready.isEmpty)
                Button { Task { await center.submitAndArm(doc.id) } } label: { BusyLabel(title: "Submit stack", busyTitle: "Submitting…", busy: job.submitting) }.buttonStyle(Pill(kind: .plain))
                    .disabled(job.submitting || !doc.tasks.contains { $0.branch.map(center.unsubmitted.contains) ?? false })
                    .help("Push this spec's finished task branches, open their pull requests, and turn on auto-merge so they land bottom first when the rules pass. Disabled when there is nothing new to push. Hands-off mode does this by itself.")
                Button("View stack") { if let r = center.repo { Nav.shared.pane = .stacks; Task { await StackCenter.shared.open(r) } } }.buttonStyle(Pill(kind: .plain))
            }.padding(12)
            if let note = job.submitNote {
                Label { job.submitFailed ? AnyView(ErrorLine(text: note)) : AnyView(Text(note)) } icon: { Image(systemName: job.submitFailed ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(job.submitFailed ? Theme.danger : Theme.ok) }
                    .font(.system(size: 12.5)).padding(.horizontal, 12).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(doc.tasks) { t in Divider(); TaskRow(doc: doc, task: t, ready: ready.contains { $0.id == t.id }) }
        }.background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

struct TaskRow: View {
    let doc: SpecDoc
    let task: SpecTask
    let ready: Bool
    let center = SpecCenter.shared

    var body: some View {
        let isMerged = task.branch.map(center.merged.contains) ?? false
        let done = task.done || isMerged
        let session = center.repo.flatMap { r in task.branch.flatMap { Workspace.shared.session(forBranch: $0, repo: r.dir, environment: r.environment) } }
        let state = session.flatMap { Workspace.shared.controller($0.id)?.state }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.ok : .secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task.id) \(task.title)").font(.system(size: 12.5, weight: .medium))
                Text([task.covers.isEmpty ? nil : "Covers \(task.covers.joined(separator: ", "))", task.needs.isEmpty ? nil : "needs \(task.needs.joined(separator: ", "))", task.pr.map { "PR #\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if done { Badge(text: "Done", kind: .ok) }
            else if state == .running || state == .waiting { Badge(text: state == .waiting ? "Needs approval" : "Running", kind: state == .waiting ? .warn : .accent) }
            else if task.pr != nil { Badge(text: "In review", kind: .accent) }
            else if task.branch.map(center.coded.contains) == true { Badge(text: "Coded", kind: .accent) }
            else if ready { AsyncButton("Run") { await center.implement(doc.id, task) }.buttonStyle(Pill(kind: .primary)) }
            else if task.branch == nil { Badge(text: "Waiting") }
            if let s = session, !done { Button("Session") { Workspace.shared.select(s.id); Nav.shared.pane = .sessions }.buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(Theme.accent) }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// A document the agent wrote, waiting for your approval. Edit it first if you like.
struct DraftCard: View {
    let doc: SpecDoc
    let draft: SpecCenter.Draft
    let center = SpecCenter.shared
    @State private var text = ""

    var body: some View {
        let file = draft.stage == .specify ? "spec.md" : draft.stage == .plan ? "plan.md" : "tasks.md"
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "doc.badge.clock").foregroundStyle(Theme.accent); Text("Review \(file)").font(.system(size: 13, weight: .semibold)); Spacer(); Badge(text: "Needs your approval", kind: .warn) }
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(height: 280).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack {
                AsyncButton("Approve and save") { await center.approve(doc.id, text: text) }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                AsyncButton("Write it again") { await center.run(doc.id, draft.stage) }.buttonStyle(Pill(kind: .plain))
                Spacer()
                Button("Discard") { center.discard(doc.id) }.buttonStyle(Pill(kind: .danger))
            }
        }
        .padding(12).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warn))
        .onAppear { text = draft.text }
    }
}

struct DocEditor: View {
    let title: String
    @State var text: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold, design: .monospaced))
            TextEditor(text: $text).font(.system(size: 12.5, design: .monospaced)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction); Button("Save") { onSave(text); dismiss() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.defaultAction) }
        }.padding(18).frame(width: 640, height: 520)
    }
}

/// Every way in. All of them end at the same draft spec.
struct NewWorkSheet: View {
    let center = SpecCenter.shared
    let ws = Workspace.shared
    @Environment(\.dismiss) private var dismiss
    enum Entry: String, CaseIterable { case issue, text, chat, code, capture, folder }
    @State private var entry: Entry = .text
    @State private var text = ""
    @State private var issue: Int?
    @State private var sessionId: String?
    @State private var branch = ""
    @State private var branches: [String] = []
    @State private var shots: [String] = []
    @State private var autonomy = Autonomy(rawValue: Prefs.shared.specAutonomy) ?? .step
    @State private var allowGit = false
    @State private var busy = false
    @State private var error: String?

    private static let cards: [(Entry, String, String)] = [
        (.issue, "A GitHub issue", "Pick from your open issues."), (.text, "Describe it", "Type or paste a requirement in your own words."),
        (.chat, "From a conversation", "Turn a session into a spec."), (.code, "From existing code", "Write the spec backwards from a branch."),
        (.capture, "From a capture", "A screenshot or error becomes the problem."), (.folder, "An existing spec", "Adopt a folder of spec documents."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New work").font(.system(size: 17, weight: .semibold))
            Text("Every way in ends at the same draft spec, so everything after it works the same.").font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(Self.cards, id: \.0) { e, t, d in
                    Button { entry = e } label: {
                        VStack(alignment: .leading, spacing: 2) { Text(t).font(.system(size: 12.5, weight: .semibold)); Text(d).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(entry == e ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(entry == e ? Theme.accent : Theme.hairline))
                    }.buttonStyle(.soft)
                }
            }
            entryBody
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("How much should the agent do on its own?")
                Segmented(options: Autonomy.allCases.map { ($0, $0.label) }, selection: $autonomy)
                Text(autonomy.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if autonomy == .hands { Toggle("Allow git add and git commit without asking in this project", isOn: $allowGit).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12)) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                AsyncButton { await go() } label: { if busy { ProgressView().controlSize(.small) } else { Text(entry == .folder ? "Choose folder…" : "Start") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(busy || !canStart).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620)
        .task {
            if let p = center.preset { entry = .text; text = p.requirement }
            await center.loadIssues()
            if let r = center.repo { branches = ((try? await Exec.with(center.env) { try await Shell.check("git", ["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: URL(fileURLWithPath: r.dir)) }) ?? "").split(separator: "\n").map(String.init).filter { $0 != center.trunk } }
            branch = branches.first ?? ""
        }
    }

    @ViewBuilder private var entryBody: some View {
        switch entry {
        case .issue:
            Dropdown(options: center.issues.map { (Int?.some($0.number), "#\($0.number) \($0.title)") }, selection: $issue, placeholder: "Choose an issue")
        case .text:
            TextEditor(text: $text).font(.system(size: 13)).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Text("Rough is fine. The agent asks about anything unclear.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .chat:
            Dropdown(options: ws.sessions.prefix(20).map { (String?.some($0.id), $0.title) }, selection: $sessionId, placeholder: "Choose a session")
        case .code:
            Dropdown(options: branches.map { ($0, $0) }, selection: $branch, placeholder: "Choose a branch")
        case .capture:
            HStack { Button("Capture the screen…") { Task { if let a = await Capture.screenshot(window: false, to: AppPaths().capturesDir) { shots.append(a.value) } } }.buttonStyle(Pill(kind: .plain)); Text(shots.isEmpty ? "No captures yet" : "\(shots.count) captured").font(.system(size: 12)).foregroundStyle(.secondary) }
            TextEditor(text: $text).font(.system(size: 13)).frame(height: 80).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Text("Say what is wrong or what you want. The picture is sent along.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .folder:
            Text("Choose a folder with spec.md (or requirements.md), plan.md (or design.md) and tasks.md. It is copied into the specs folder.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var canStart: Bool {
        switch entry {
        case .issue: issue != nil
        case .text, .capture: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .chat: sessionId != nil
        case .code: !branch.isEmpty
        case .folder: center.env == nil
        }
    }

    private func go() async {
        busy = true; error = nil; defer { busy = false }
        Prefs.shared.specAutonomy = autonomy.rawValue
        var source: SpecSource?
        switch entry {
        case .issue:
            guard let n = issue, let r = center.repo else { return }
            guard let full = try? await Exec.with(center.env, { try await GitHub.issue(n, in: r.dir) }) else { error = "Could not read that issue."; return }
            source = SpecSource(label: "Issue #\(n)", title: full.title, requirement: full.requirementText())
        case .text:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            source = SpecSource(label: center.preset?.label ?? "Described by you", title: center.preset?.title ?? String(t.split(separator: "\n").first?.prefix(60) ?? "New work"), requirement: t)
        case .chat:
            guard let id = sessionId, let m = ws.sessions.first(where: { $0.id == id }) else { return }
            let digest = ContextDigest.build(items: ws.store.items(id), budget: 7000)
            source = SpecSource(label: "Session \"\(m.title)\"", title: m.title, requirement: "Turn the idea discussed in this conversation into a specification. Conversation summary:\n\n\(digest)")
        case .code:
            guard let s = await center.codeSource(branch: branch) else { error = "That branch has no changes compared with the trunk."; return }
            source = s
        case .capture:
            let imgs = shots.compactMap { p in (try? Data(contentsOf: URL(fileURLWithPath: p))).map { (mediaType: "image/png", data: $0) } }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            source = SpecSource(label: "Capture", title: String(t.split(separator: "\n").first?.prefix(60) ?? "From a capture"), requirement: t, images: imgs)
        case .folder:
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
            if p.runModal() == .OK, let u = p.url { await center.importFolder(u); dismiss() }
            return
        }
        guard let src = source else { return }
        center.preset = nil
        dismiss()
        await center.start(src, autonomy: autonomy, allowGit: allowGit)
    }
}
