// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// One file of a diff: header, then numbered lines with added and removed lines tinted.
struct DiffFileView: View {
    let file: DiffFile
    let collapsed: Bool
    let toggle: () -> Void
    @State private var limit = 300

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    if file.isNew { Badge(text: "New", kind: .ok) }
                    if file.isDeleted { Badge(text: "Deleted", kind: .danger) }
                    Spacer()
                    Text("+\(file.additions)").foregroundStyle(Theme.ok).font(.system(size: 11.5, design: .monospaced))
                    Text("−\(file.deletions)").foregroundStyle(Theme.danger).font(.system(size: 11.5, design: .monospaced))
                }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.soft)
            if !collapsed {
                Divider()
                if file.isBinary { Text("Binary file").font(.system(size: 12)).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    ScrollView(.horizontal) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(file.lines.prefix(limit)) { l in line(l) }
                            if file.lines.count > limit {
                                Button("Show \(min(300, file.lines.count - limit)) more lines") { limit += 300 }.buttonStyle(.soft).foregroundStyle(Theme.accent)
                                    .font(.system(size: 12)).padding(8)
                            }
                        }.frame(minWidth: 600, alignment: .leading)
                    }.background(Theme.terminal)
                }
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }

    private func line(_ l: DiffLine) -> some View {
        HStack(spacing: 0) {
            if l.kind == .hunk {
                Text(l.text).foregroundStyle(Color.white.opacity(0.45)).padding(.leading, 90)
            } else {
                Text(l.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(Color.white.opacity(0.3))
                Text(l.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(Color.white.opacity(0.3))
                Text(l.kind == .added ? " + " : l.kind == .removed ? " − " : "   ").foregroundStyle(l.kind == .added ? Color.green : Color.red.opacity(0.9))
                Text(l.text.isEmpty ? " " : l.text).foregroundStyle(Color.white.opacity(0.88))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
        .padding(.vertical, 1)
        .background(l.kind == .added ? Color.green.opacity(0.14) : l.kind == .removed ? Color.red.opacity(0.16) : l.kind == .hunk ? Color.white.opacity(0.05) : .clear)
    }
}

/// Create a pull request from a folder's current branch: push it, draft the text with Claude if you like, open the PR.
struct CreatePRSheet: View {
    let dir: String
    var env: EnvironmentConfig?
    /// Hands a request to the agent already working in this folder. Without one, a session of its own is started.
    var askAgent: ((String) -> Void)?
    var onCreated: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var standing: Git.BaseCheck?
    @State private var title = ""
    @State private var prBody = ""
    @State private var base = "main"
    @State private var branch = ""
    @State private var draft = false
    @State private var busy = false
    @State private var drafting = false
    @State private var error: String?
    @State private var failure: ErrorReport?
    @State private var baseLog: [Git.Commit] = []
    @State private var mine: [Git.Commit] = []
    @State private var sameChange: [Git.Duplicate] = []

    /// Titles (the pull request's and its commits') that the base branch already has, and changes it already has under another title.
    private var duplicates: [Git.Duplicate] {
        Git.findDuplicates([("title", title)] + mine.map { ($0.sha, $0.subject) }, baseLog: baseLog) + sameChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.system(size: 17, weight: .semibold))
            Text("\(branch) → \(base)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            TextField("Title", text: $title).textFieldStyle(CPField())
            if !duplicates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(duplicates.contains { !$0.sameChange } ? "\(base) already has a commit with this title" : "\(base) already has this change", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                    ForEach(duplicates.prefix(3)) { x in
                        Text(x.sameChange ? "commit \(x.mine)  \(x.subject)  ←  same change is already on \(base)"
                                          : "\(x.onBase)  \(x.subject)  ←  \(x.mine == "title" ? "this title" : "commit \(x.mine)")")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("It may be the same change committed twice. Give the pull request a title that describes all of it, or check that this work is not already on \(base).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9))
            }
            if let standing, !standing.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(base) has moved and conflicts with this branch", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                    Text(standing.conflicts.prefix(4).joined(separator: ", ") + (standing.conflicts.count > 4 ? " and \(standing.conflicts.count - 4) more" : ""))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    Text("Opening the pull request now would leave it stuck on GitHub. Claude can bring \(base) into the branch and resolve this here first.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { resolveWithClaude(standing) } label: { Label("Resolve with Claude", systemImage: "sparkles") }.buttonStyle(Pill(kind: .primary))
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9))
            } else if let standing, standing.behind > 0 {
                Label("\(base) is \(standing.behind) commit\(standing.behind == 1 ? "" : "s") ahead. It is brought in cleanly before the pull request opens.", systemImage: "arrow.triangle.merge")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            TextEditor(text: $prBody).font(.system(size: 12.5)).frame(height: 140).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack {
                Toggle("Draft", isOn: $draft)
                Spacer()
                AsyncButton { await writeWithClaude() } label: {
                    if drafting { ProgressView().controlSize(.small) } else { Label("Write with Claude", systemImage: "sparkles") }
                }.buttonStyle(Pill(kind: .plain)).disabled(drafting || busy)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                AsyncButton { await create() } label: { if busy { ProgressView().controlSize(.small) } else { Text("Create") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(title.isEmpty || busy || !(standing?.conflicts.isEmpty ?? true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $failure) { ErrorReportSheet(report: $0) }
        .task {
            await Exec.with(env) {
                branch = await Git.info(dir)?.branch ?? ""
                base = await Git.defaultBranch(dir)
                baseLog = await Git.baseLog(dir, base: base)
                mine = await Git.commits(dir, since: "origin/\(base)")
                // Only a commit of this branch can name the pull request. With none yet, HEAD is the base's own last commit, whose title is not ours.
                if !mine.isEmpty {
                    title = ((try? await Shell.check("git", ["log", "-1", "--format=%s"], cwd: URL(fileURLWithPath: dir))) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                standing = await Git.checkAgainstBase(dir, base: base, branch: branch)
                sameChange = await Git.alreadyOnBase(dir, base: base, head: "HEAD", subjects: Dictionary(mine.map { ($0.sha, $0.subject) }, uniquingKeysWith: { a, _ in a }))
            }
        }
    }

    private func resolveWithClaude(_ c: Git.BaseCheck) {
        let how = c.pushed
            ? "This branch is already on the remote, so run `git merge origin/\(base)` (do not rebase or force-push)."
            : "This branch has not been pushed, so run `git rebase origin/\(base)`."
        let prompt = "I am about to open a pull request from \(branch) into \(base), but \(base) has moved and conflicts with this branch in: \(c.conflicts.joined(separator: ", ")). \(how) Resolve the conflicts so both sides' intent is kept, run the tests, `git add` the files and finish the \(c.pushed ? "merge" : "rebase"). Do not push and do not open the pull request: I will do that from CPilot once it is clean."
        if let askAgent { askAgent(prompt) }
        else {
            let level: AccessLevel = [.readOnly, .askFirst].contains(Workspace.shared.policy.defaultLevel) ? .editFiles : Workspace.shared.policy.defaultLevel
            Task { do { try await Workspace.shared.create(.init(folder: dir, access: level, firstMessage: prompt, environment: env?.id, title: "Resolve conflict: \(branch)")) }
                   catch { AppModel.shared.fail(error, action: "Start the session that resolves the conflict") } }
        }
        AppModel.shared.show("Claude is resolving the conflict. Create the pull request when it is done.")
        dismiss()
    }

    private func writeWithClaude() async {
        await Exec.with(env) { await writeWithClaudeImpl() }
    }

    private func writeWithClaudeImpl() async {
        drafting = true; defer { drafting = false }
        let diff = String((await Git.diff(dir, base: "origin/\(base)")).prefix(30000))
        let prompt = "Write a pull request title (one line, under 70 characters) and a short description for this diff. Reply with the title on the first line, then a blank line, then the description in plain Markdown. No preamble.\n\n\(diff)"
        guard let out = await ClaudeOneShot.run(prompt, in: dir, timeout: 120) else { error = "Claude could not write the text. Write it yourself."; return }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        title = (parts.first ?? "").replacingOccurrences(of: "# ", with: "")
        prBody = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() async {
        await Exec.with(env) { await createImpl() }
    }

    private func createImpl() async {
        busy = true; error = nil; defer { busy = false }
        do {
            if await Git.uncommittedCount(dir) > 0 { try await Git.commitAll(dir, message: title.isEmpty ? "Update" : title) }
            if await Git.commitsAhead(dir, of: "origin/\(base)") == 0 {
                error = "This branch has no changes compared with \(base), so there is nothing to open a pull request for."
                return
            }
            // Settle the base first: a pull request opened over a conflict sits on GitHub, flagged, until someone notices.
            if let check = await Git.checkAgainstBase(dir, base: base, branch: branch) {
                standing = check
                if !check.conflicts.isEmpty { return }
                if check.behind > 0 { try await Git.catchUp(dir, base: base, pushed: check.pushed); standing?.behind = 0 }
            }
            try await Git.push(dir, branch: branch)
            let url = try await GitHub.create(title: title, body: prBody, base: base, draft: draft, in: dir)
            let n = Int(url.split(separator: "/").last ?? "") ?? 0
            AppModel.shared.show("Pull request created")
            dismiss(); onCreated(n)
        } catch {
            let r = ErrorReport(error, action: "Create the pull request")
            self.error = r.message; failure = r
        }
    }
}

/// The strip under a session's chat: the branch it is on now, its commits, and the pull request (open or already merged) or a way to make one.
/// A session can move to another branch (the agent starts a fix branch and opens its own PR), so this follows what is checked out, not what the
/// session started on, and keeps the branch it started on as a second entry.
struct SessionPRBar: View {
    let session: SessionController
    private struct Entry: Identifiable { let branch: String; let pr: PullRequest?; var id: String { branch } }
    @State private var entries: [Entry] = []
    @State private var commits: [Git.Commit] = []
    @State private var showCommits = false
    @State private var showCreate = false
    @State private var stackPos: String?
    @State private var opening = false

    private var current: Entry? { entries.first }
    private var pr: PullRequest? { current?.pr }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
            Text(current?.branch ?? session.meta.branch ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1)
            if let stackPos { Badge(text: stackPos, kind: .accent) }
            if let pr {
                Button { open(pr.number) } label: { Badge(text: "#\(pr.number)", kind: .accent) }
                    .buttonStyle(.soft).help("Open pull request #\(pr.number)")
                if pr.state == "MERGED" { Badge(text: "Merged", kind: .ok) }
                else if pr.state == "CLOSED" { Badge(text: "Closed", kind: .neutral) }
                else if pr.autoMerge { Badge(text: "Auto-merge", kind: .ok) }
                else if pr.isOpen, pr.mergeStateStatus == "DIRTY" {
                    Button { session.draft = conflictPrompt(pr); session.send() } label: { Badge(text: "Conflicts · Fix with Claude", kind: .danger) }
                        .buttonStyle(.soft).help("Ask the agent to bring \(pr.baseRefName) into the branch and resolve the conflicts")
                } else if pr.isOpen, pr.mergeStateStatus == "UNSTABLE" {
                    Button { session.draft = checksPrompt(pr); session.send() } label: { Badge(text: "Checks failing · Fix with Claude", kind: .danger) }
                        .buttonStyle(.soft).help("Ask the agent to read the failing checks and fix them")
                }
            }
            if !commits.isEmpty {
                Button { showCommits.toggle() } label: {
                    Label("\(commits.count) commit\(commits.count == 1 ? "" : "s")", systemImage: "clock.arrow.circlepath").font(.system(size: 11.5))
                }.buttonStyle(.soft).foregroundStyle(.secondary)
                .popover(isPresented: $showCommits, arrowEdge: .top) { CommitList(commits: commits) }
            }
            ForEach(entries.dropFirst()) { e in
                Divider().frame(height: 14)
                Button { if let n = e.pr?.number { open(n) } } label: {
                    HStack(spacing: 5) {
                        Text(e.branch).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        if let n = e.pr?.number { Badge(text: "#\(n)", kind: .neutral) }
                    }
                }.buttonStyle(.soft).foregroundStyle(.secondary).disabled(e.pr == nil)
                .help(e.pr == nil ? "This session also touched \(e.branch)" : "Open pull request #\(e.pr!.number) on \(e.branch)")
            }
            Spacer()
            if let pr {
                Button { open(pr.number) } label: {
                    HStack(spacing: 6) { if opening { ProgressView().controlSize(.mini) }; Text(opening ? "Opening…" : pr.isOpen ? "Review & merge" : "View PR") }
                }.buttonStyle(Pill(kind: pr.isOpen ? .primary : .plain)).disabled(opening)
            } else {
                Button("Create PR") { showCreate = true }.buttonStyle(Pill(kind: .plain))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7).background(Theme.sidebar.opacity(0.6))
        // Reload when the branch changes and whenever a turn ends, since that is when the agent may have pushed or switched.
        .task(id: "\(session.meta.branch ?? "")|\(session.state)") { await load() }
        // A pull request is often merged somewhere else (GitHub, the Pull requests pane), which changes nothing here, so an open one is looked at again
        // every so often, and whenever you come back to the app.
        .task(id: pr?.number) { while !Task.isCancelled, pr?.isOpen == true { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
        .sheet(isPresented: $showCreate) { CreatePRSheet(dir: session.meta.workingDirectory, env: session.env, askAgent: { session.draft = $0; session.send() }) { _ in Task { await load(); CIWatcher.shared.nudge() } } }
    }

    private func conflictPrompt(_ pr: PullRequest) -> String {
        "Pull request #\(pr.number) conflicts with \(pr.baseRefName). Run `git fetch origin` and `git merge origin/\(pr.baseRefName)` (do not rebase or force-push, the branch is already on GitHub), resolve the conflicts so both sides' intent is kept, run the tests, commit the merge and push."
    }

    private func checksPrompt(_ pr: PullRequest) -> String {
        "The checks on pull request #\(pr.number) are failing. Run `gh pr checks \(pr.number)` and read the failing logs with `gh run view --log-failed`, fix the cause, run the tests locally, then commit and push to this branch."
    }

    private func open(_ n: Int) {
        opening = true
        Task { await PRCenter.shared.jump(repo: session.meta.cwd, environment: session.meta.environment, number: n); opening = false }
    }

    private func pullRequest(for branch: String) async -> PullRequest? {
        let out = try? await Exec.with(session.env) { try await Shell.check("gh", ["pr", "list", "--head", branch, "--state", "all", "--json", PullRequest.listFields], cwd: URL(fileURLWithPath: session.meta.cwd)) }
        let found = out.flatMap { try? JSONDecoder().decode([PullRequest].self, from: Data($0.utf8)) } ?? []
        // An open PR wins; otherwise the newest one, so a merged session says so instead of offering "Create PR".
        return found.first(where: \.isOpen) ?? found.max(by: { $0.number < $1.number })
    }

    private func load() async {
        if session.state == .running || session.state == .waiting { return }   // reloads once the turn ends
        let dir = session.meta.workingDirectory
        let now = await Exec.with(session.env) { await Git.info(dir)?.branch } ?? ""
        var names: [String] = []
        for b in [now, session.meta.branch ?? ""] where !b.isEmpty && !names.contains(b) { names.append(b) }
        guard !names.isEmpty else { return }
        var list: [Entry] = []
        for b in names { list.append(Entry(branch: b, pr: await pullRequest(for: b))) }
        entries = list
        let primary = list[0]
        commits = await Exec.with(session.env) {
            // A merged branch has nothing ahead of main any more, so the pull request is the record of what it carried.
            if let pr = primary.pr, !pr.isOpen { return await GitHub.commits(pr.number, in: session.meta.cwd) }
            let base = await Git.defaultBranch(dir)
            return await Git.commits(dir, since: "origin/\(base)")
        }
        let stacks = await Exec.with(session.env) { await Stacks.load(in: session.meta.cwd) }
        if let st = stacks.first(where: { $0.branches.contains { $0.name == primary.branch } }), st.branches.count > 1, let i = st.branches.firstIndex(where: { $0.name == primary.branch }) { stackPos = "Stack \(i + 1) of \(st.branches.count)" } else { stackPos = nil }
    }
}

private struct CommitList: View {
    let commits: [Git.Commit]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(commits) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(c.sha).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accent)
                        Text(c.subject).font(.system(size: 12.5)).lineLimit(2)
                        Spacer(minLength: 12)
                        Text(c.when).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
        }.frame(width: 440).frame(maxHeight: 320)
    }
}
