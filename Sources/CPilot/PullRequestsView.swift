// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Pull request state for the screen: list, detail, diff, checks, security scan and the merge gate.
@MainActor @Observable
final class PRCenter {
    static let shared = PRCenter()
    var repoDir: String?
    /// The server the repository is on; nil is this Mac.
    var env: EnvironmentConfig?
    var prs: [PullRequest] = []
    var selected: Int?
    var detail: PullRequest?
    var files: [DiffFile] = []
    var checks: [PullRequest.Check] = []
    /// The commits the pull request carries, newest first.
    var commits: [Git.Commit] = []
    var scan: SecurityResult?
    var scanning = false
    var scanLog: [String] = []
    var loading = false
    var method: MergeMethod = .squash
    var fileFilter = ""
    /// Titles this pull request would add to its base branch that the base already has (the same change landing twice).
    var duplicates: [Git.Duplicate] = []
    var restacking = false
    var titleDraft = ""
    /// Merge styles the repository allows, and a suggestion with its reason.
    var allowed: Set<MergeMethod> = Set(MergeMethod.allCases)
    var recommended: (method: MergeMethod, reason: String)?
    var showCreate = false
    var showInbox = false
    /// Pull requests CPilot merges by itself the moment every rule passes: "owner/repo#number" -> repo folder.
    var armed: [String: String] = UserDefaults.standard.dictionary(forKey: "armedMerges") as? [String: String] ?? [:]
    private let scanStore = ScanStore()                  // on disk, by repository + number + head commit, so a re-open or a restart does not rescan
    private func scanKey(_ dir: String, _ pr: PullRequest) -> String { "\(dir)#\(pr.number)#\(pr.headRefOid ?? pr.headRefName)" }
    private var watcher: Task<Void, Never>?
    /// Armed pull requests already reported as unable to merge, by repository, number and head commit, so the minute-by-minute check says it once.
    private var cantMergeTold: Set<String> = []
    /// Open pull requests per repository, so the screen shows something at once and refreshes behind it.
    private var cache: [String: (prs: [PullRequest], at: Date)] = [:]
    private func cacheKey(_ dir: String, _ environment: String?) -> String { dir + "|" + (environment ?? "") }

    var gate: MergeGate? {
        guard let pr = detail else { return nil }
        return MergeGate.evaluate(pr: pr, checks: checks, scan: scan, requireScan: Prefs.shared.securityScanOnPR)
    }

    struct Repo: Hashable { var dir: String; var environment: String?
        @MainActor var name: String { URL(fileURLWithPath: dir).lastPathComponent + (environment.flatMap { Workspace.shared.environment($0)?.name }.map { " · \($0)" } ?? "") } }

    func repos() -> [Repo] { Project.shared.repos() }
    var currentRepo: Repo? { repoDir.map { Repo(dir: $0, environment: env?.id) } }

    func open(repo: String, environment: String? = nil) async {
        guard !AppModel.shared.demo else { return }
        switchRepo(repo, environment)
        if let c = cache[cacheKey(repo, environment)], Date().timeIntervalSince(c.at) < 20 { return }
        await refreshList()
    }

    /// Loads a repository's pull requests ahead of the screen being opened.
    func warm(_ r: Repo?) async {
        guard let r, !AppModel.shared.demo else { return }
        let key = cacheKey(r.dir, r.environment)
        if let c = cache[key], Date().timeIntervalSince(c.at) < 20 { return }
        let list = await Exec.with(Workspace.shared.environment(r.environment)) { try? await GitHub.list(in: r.dir, state: "open") }
        guard let list else { return }
        cache[key] = (list, .now)
        if repoDir == r.dir, env?.id == r.environment { prs = list }
    }

    private func switchRepo(_ repo: String, _ environment: String?) {
        repoDir = repo; env = Workspace.shared.environment(environment); selected = nil; detail = nil; files = []
        prs = cache[cacheKey(repo, environment)]?.prs ?? []
        Project.shared.current = Repo(dir: repo, environment: environment)
    }

    /// Jumps straight to one pull request: the screen switches at once and the list and the detail load side by side.
    func jump(repo: String, environment: String?, number: Int) async {
        switchRepo(repo, environment)
        selected = number
        AppDelegate.shared.showManager(pane: .pulls)
        async let list: Void = refreshList()
        await select(number)
        await list
        // A pull request created a moment ago can be missing from GitHub's list while its detail already loads.
        if let d = detail, d.number == number, d.isOpen, !prs.contains(where: { $0.number == number }) {
            prs.insert(d, at: 0); cache[cacheKey(repo, environment)] = (prs, .now)
        }
    }
    func open(_ r: Repo) async { await open(repo: r.dir, environment: r.environment) }

    func refreshList() async {
        await Exec.with(env) { await refreshListImpl() }
    }

    private func refreshListImpl() async {
        guard let dir = repoDir else { return }
        loading = true; defer { loading = false }
        do { prs = try await GitHub.list(in: dir, state: "open"); cache[cacheKey(dir, env?.id)] = (prs, .now) } catch { AppModel.shared.failQuietly(error, action: "Load pull requests"); return }
        // The pull request on screen was open and is not in the open list any more: it was merged or closed elsewhere (GitHub, auto-merge, another session).
        if let n = selected, detail?.number == n, detail?.isOpen == true, !prs.contains(where: { $0.number == n }) { selected = nil; detail = nil; files = []; checks = [] }
    }

    /// Reads the open list and the selected pull request again, after something outside this screen moved their branches.
    func refreshOpen() async {
        guard repoDir != nil, !AppModel.shared.demo else { return }
        await Exec.with(env) {
            await refreshList()
            if let n = selected { await selectImpl(n) }
        }
    }

    /// Quietly reads the open list, the selected pull request and its checks again, without blanking what is on screen,
    /// so a check that finishes shows up while the pane is open.
    func refreshLive() async {
        guard let dir = repoDir, !AppModel.shared.demo, !loading else { return }
        await Exec.with(env) {
            await refreshListImpl()
            guard let n = selected, detail?.number == n, detail?.isOpen == true else { return }
            async let pr = try? GitHub.view(n, in: dir)
            async let chk = GitHub.checks(n, in: dir)
            let (p, c) = await (pr, chk)
            guard selected == n, let p else { return }
            detail = p; checks = c
        }
    }

    func select(_ n: Int) async {
        await Exec.with(env) { await selectImpl(n) }
    }

    private func selectImpl(_ n: Int) async {
        guard let dir = repoDir else { return }
        selected = n; detail = nil; files = []; checks = []; commits = []; scan = nil; scanLog = []; duplicates = []; recommended = nil
        do {
            async let pr = GitHub.view(n, in: dir)
            async let diff = GitHub.diff(n, in: dir)
            async let chk = GitHub.checks(n, in: dir)
            async let cm = GitHub.commits(n, in: dir)
            let (p, d, c) = try await (pr, diff, chk)
            let cl = await cm
            guard selected == n else { return }
            detail = p; files = DiffParser.parse(d); checks = c; commits = cl
            scan = scanStore.result(for: scanKey(dir, p))
            titleDraft = p.title
            if p.isOpen { await findDuplicates(p, dir: dir) }
        } catch { AppModel.shared.failQuietly(error, action: "Load the pull request") }
    }

    /// Looks at what the merge would do before the button is pressed: titles or changes the base already has, which styles are allowed,
    /// and which one keeps this pull request's commits intact.
    private func findDuplicates(_ p: PullRequest, dir: String) async {
        let commits = await GitHub.commits(p.number, in: dir)
        async let log = Git.baseLog(dir, base: p.baseRefName)
        async let allowedNow = GitHub.allowedMethods(in: dir)
        _ = try? await Shell.run("git", ["fetch", "origin", "pull/\(p.number)/head"], cwd: URL(fileURLWithPath: dir), timeout: 120)
        let titles = Git.findDuplicates([("title", p.title)] + commits.map { ($0.sha, $0.subject) }, baseLog: await log)
        let subjects = Dictionary(commits.map { ($0.sha, $0.subject) }, uniquingKeysWith: { a, _ in a })
        var same = await Git.alreadyOnBase(dir, base: p.baseRefName, head: "FETCH_HEAD", subjects: subjects)
        same.removeAll { s in titles.contains { $0.mine == s.mine } }
        let merges = await Git.mergeCommitCount(dir, base: p.baseRefName, head: "FETCH_HEAD")
        let ok = await allowedNow
        guard selected == p.number else { return }
        duplicates = titles + same
        allowed = ok
        recommended = Self.recommend(commits: commits.count, merges: merges, allowed: ok)
        if !ok.contains(method), let first = [MergeMethod.squash, .merge, .rebase].first(where: ok.contains) { method = first }
    }

    /// One commit, or a branch that merged main into itself: squash. Several clean commits: whatever the repository allows, squash first.
    nonisolated static func recommend(commits: Int, merges: Int, allowed: Set<MergeMethod>) -> (method: MergeMethod, reason: String)? {
        if merges > 0, allowed.contains(.squash) { return (.squash, "This branch contains \(merges) merge commit\(merges == 1 ? "" : "s"), which a rebase merge would flatten away.") }
        if commits <= 1, allowed.contains(.squash) { return (.squash, "A single commit lands the same way with any style.") }
        if allowed.count == 1, let only = allowed.first { return (only, "It is the only style this repository allows.") }
        return nil
    }

    func retitle(_ title: String) async {
        await Exec.with(env) {
            guard let dir = repoDir, let n = selected else { return }
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            do { try await GitHub.retitle(n, to: t, in: dir); AppModel.shared.show("Title updated"); await selectImpl(n) }
            catch { AppModel.shared.fail(error, action: "Rename the pull request") }
        }
    }

    /// A pull request stacked on one that has since been merged still carries that one's commit until it is rebased onto the base.
    /// Renaming cannot fix that: this puts the stack back on top of the base and pushes it, so only this pull request's own commits are left.
    func restackAndPush() async {
        await Exec.with(env) {
            guard let dir = repoDir, let p = detail else { return }
            restacking = true; defer { restacking = false }
            do {
                let host = LiveStackHost(dir: dir)
                _ = try await Stacks.sync(in: dir, host: host)
                if let stack = await Stacks.load(in: dir, host: host).first(where: { $0.branches.contains { $0.name == p.headRefName } }) {
                    _ = try await Stacks.submit(stack, in: dir, host: host)
                }
                AppModel.shared.show("Restacked onto \(p.baseRefName) and pushed")
                await selectImpl(p.number)
            } catch let e as StackError {
                if case .conflict = e { AppModel.shared.show("Restacking hit a conflict. Resolve it in Stacks.", error: true) } else { AppModel.shared.fail(e, action: "Restack") }
            } catch { AppModel.shared.fail(error, action: "Restack") }
        }
    }

    /// A title for the whole pull request, not just its first commit.
    func suggestTitle() async {
        await Exec.with(env) {
            guard let dir = repoDir, let p = detail else { return }
            let list = await GitHub.commits(p.number, in: dir).map { "- " + $0.subject }.joined(separator: "\n")
            let prompt = "Write one commit title (under 70 characters, no quotes, no trailing period) that describes everything this pull request does, not only its first commit. Reply with the title only.\n\nCurrent title: \(p.title)\nCommits:\n\(list)\n\nDescription:\n\(Stacks.withoutFooter(p.body ?? "").prefix(1500))"
            if let out = await ClaudeOneShot.run(prompt, in: dir, timeout: 90) { titleDraft = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? out }
            else { AppModel.shared.show("Claude could not suggest a title. Write one yourself.", error: true) }
        }
    }

    func runScan() async {
        await Exec.with(env) { await runScanImpl() }
    }

    private func runScanImpl() async {
        guard let dir = repoDir, let pr = detail else { return }
        scanning = true; scanLog = []; defer { scanning = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cpilot-scan-\(pr.number)-\(UUID().uuidString.prefix(6))").path
        do {
            _ = try await Shell.check("git", ["fetch", "origin", "pull/\(pr.number)/head"], cwd: URL(fileURLWithPath: dir), timeout: 120)
            try await Shell.check("git", ["worktree", "add", "--detach", tmp, "FETCH_HEAD"], cwd: URL(fileURLWithPath: dir))
            let mode = await SecurityCage.chooseMode(baseURL: Prefs.shared.localModelURL)
            scanLog.append(mode.note)
            let result = try await SecurityCage.scan(folder: tmp, deep: mode.deep, environment: mode.environment, configured: Prefs.shared.securityCagePath) { [weak self] line in Task { @MainActor in self?.scanLog.append(line) } }
            scan = result; scanStore.save(result, for: scanKey(dir, pr))
        } catch { AppModel.shared.fail(error, action: "Run the security scan") }
        await Git.removeWorktree(repo: dir, path: tmp)
    }

    func review(_ action: ReviewAction, body: String = "") async {
        await Exec.with(env) { await reviewImpl(action, body: body) }
    }

    private func reviewImpl(_ action: ReviewAction, body: String = "") async {
        guard let dir = repoDir, let n = selected else { return }
        do { try await GitHub.review(n, action: action, body: body, in: dir); AppModel.shared.show(action == .approve ? "Approved" : "Review sent"); await select(n) }
        catch { AppModel.shared.fail(error, action: "Send the review") }
    }

    func mergeNow() async {
        await Exec.with(env) { await mergeNowImpl() }
    }

    private func mergeNowImpl() async {
        guard let dir = repoDir, let n = selected else { return }
        // What the reviewer saw. If the branch moves before GitHub merges, the merge is refused instead of leaving the new commits behind.
        let head = detail?.headRefOid, base = detail?.baseRefName ?? "main", names = files.map(\.path)
        do {
            do { try await GitHub.merge(n, method: method, auto: false, expectedHead: head, in: dir) }
            catch where GitHub.isPolicyBlock(error) {
                guard confirmAdminMerge(n) else { return }
                try await GitHub.merge(n, method: method, auto: false, admin: true, expectedHead: head, in: dir)
            }
            disarm(n)
            await refreshList(); selected = nil; detail = nil
            await announceMerged(n, head: head, base: base, files: names, dir: dir)
        } catch where GitHub.isHeadMoved(error) {
            AppModel.shared.show("#\(n) got new commits while you were looking. Nothing was merged. Review the new commits and merge again.", error: true)
            await selectImpl(n)
        } catch { AppModel.shared.fail(error, action: "Merge") }
    }

    /// Says it is merged, and whether everything the pull request changed is on the base branch exactly as reviewed.
    private func announceMerged(_ n: Int, head: String?, base: String, files: [String], dir: String) async {
        guard let head, !files.isEmpty else { AppModel.shared.show("Merged #\(n)"); return }
        let differing = await Git.filesDiffering(dir, head: head, base: base, files: files)
        if differing.isEmpty { AppModel.shared.show("Merged #\(n). Checked: all \(files.count) changed file\(files.count == 1 ? "" : "s") match what you reviewed.") }
        else { AppModel.shared.show("Merged #\(n). \(differing.count) file\(differing.count == 1 ? "" : "s") on \(base) differ from the branch (\(differing.prefix(2).joined(separator: ", "))\(differing.count > 2 ? "…" : "")). Expected if \(base) changed them too; check if not.", error: false) }
    }

    private func confirmAdminMerge(_ n: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Merge #\(n) using your bypass rule?"
        alert.informativeText = "The branch policy blocks this merge. If you can bypass it, GitHub will merge without waiting for the requirements."
        alert.addButton(withTitle: "Merge anyway"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func post(comment: String) async {
        await Exec.with(env) { await postImpl(comment: comment) }
    }

    private func postImpl(comment: String) async {
        guard let dir = repoDir, let n = selected else { return }
        do { try await GitHub.comment(n, body: comment, in: dir); AppModel.shared.show("Comment posted") } catch { AppModel.shared.fail(error, action: "Post the comment") }
    }

    // MARK: Auto-merge. Polls only while something is armed.

    private func key(_ n: Int) -> String { "\(repoDir ?? "")#\(n)" }
    func isArmed(_ n: Int) -> Bool { armed[key(n)] != nil }

    func setArmed(_ on: Bool, _ n: Int) {
        guard let dir = repoDir else { return }
        if on { armed[key(n)] = dir } else { armed[key(n)] = nil }
        persistArmed(); startWatcher()
    }
    private func disarm(_ n: Int) { armed[key(n)] = nil; persistArmed() }
    private func persistArmed() { UserDefaults.standard.set(armed, forKey: "armedMerges") }

    func startWatcher() {
        watcher?.cancel(); watcher = nil
        guard !armed.isEmpty else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkArmed()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func checkArmed() async {
        for (k, dir) in armed {
            guard let n = Int(k.split(separator: "#").last ?? "") else { continue }
            guard let pr = try? await GitHub.view(n, in: dir) else { continue }
            if !pr.isOpen { armed[k] = nil; persistArmed(); continue }
            let chk = await GitHub.checks(n, in: dir)
            let key = scanKey(dir, pr)
            var result = scanStore.result(for: key)
            if result == nil, Prefs.shared.securityScanOnPR, let r = await scanQuietly(pr, dir: dir) { result = r; scanStore.save(r, for: key) }
            let gate = MergeGate.evaluate(pr: pr, checks: chk, scan: result, requireScan: Prefs.shared.securityScanOnPR)
            if gate.ready {
                do {
                    try await GitHub.merge(n, method: method, auto: false, expectedHead: pr.headRefOid, in: dir)
                    armed[k] = nil; persistArmed()
                    AppModel.shared.notify("Merged #\(n)", body: pr.title)
                } catch { AppLog.error(error, context: "auto-merge #\(n)") }
            } else if !chk.contains(where: { !$0.passed }), cantMergeTold.insert(key).inserted {
                AppModel.shared.notify("#\(n) can't merge yet", body: gate.reasons.first ?? pr.title)
            }
        }
        if armed.isEmpty { watcher?.cancel(); watcher = nil }
        await refreshList()
    }

    /// Can this pull request be merged now? Runs the security scan first if that is required and has not been done.
    /// Call inside `Exec.with` for a server's repository.
    func gateFor(_ n: Int, dir: String) async -> MergeGate {
        guard let pr = try? await GitHub.view(n, in: dir) else { return MergeGate(ready: false, reasons: ["Could not read the pull request."]) }
        let chk = await GitHub.checks(n, in: dir)
        let key = scanKey(dir, pr)
        var result = scanStore.result(for: key)
        if result == nil, Prefs.shared.securityScanOnPR, let r = await scanQuietly(pr, dir: dir) { result = r; scanStore.save(r, for: key) }
        return MergeGate.evaluate(pr: pr, checks: chk, scan: result, requireScan: Prefs.shared.securityScanOnPR)
    }

    private func scanQuietly(_ pr: PullRequest, dir: String) async -> SecurityResult? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cpilot-scan-\(pr.number)-\(UUID().uuidString.prefix(6))").path
        defer { Task { await Git.removeWorktree(repo: dir, path: tmp) } }
        guard (try? await Shell.check("git", ["fetch", "origin", "pull/\(pr.number)/head"], cwd: URL(fileURLWithPath: dir), timeout: 120)) != nil,
              (try? await Shell.check("git", ["worktree", "add", "--detach", tmp, "FETCH_HEAD"], cwd: URL(fileURLWithPath: dir))) != nil else { return nil }
        let mode = await SecurityCage.chooseMode(baseURL: Prefs.shared.localModelURL)
        return try? await SecurityCage.scan(folder: tmp, deep: mode.deep, environment: mode.environment, configured: Prefs.shared.securityCagePath) { _ in }
    }

    /// Starts a session on the pull request's branch, in its own worktree, asking the agent to review or to fix a finding.
    /// Full access unless `readOnly`; servers never get Full access, so they start with Edit files.
    func startSession(prompt: String, title: String, readOnly: Bool) async {
        await Exec.with(env) { await startSessionImpl(prompt: prompt, title: title, readOnly: readOnly) }
    }

    private func startSessionImpl(prompt: String, title: String, readOnly: Bool) async {
        guard let dir = repoDir, let pr = detail else { return }
        do { _ = try await startSession(on: pr, dir: dir, prompt: prompt, title: title, readOnly: readOnly) }
        catch { AppModel.shared.fail(error, action: "Start the session") }
    }

    /// A session on a pull request's branch, in a worktree of its own. `show: false` leaves the screen alone (the chief pilot starts these).
    /// `reviewOf` marks it as the pull request's reviewer.
    @discardableResult
    func startSession(on pr: PullRequest, dir: String, prompt: String, title: String, readOnly: Bool, show: Bool = true, reviewOf: Int? = nil) async throws -> SessionController {
        let branch = "review-\(pr.number)-\(Int(Date().timeIntervalSince1970) % 100000)"
        let path = AppPaths().root.appendingPathComponent("worktrees/pr-\(pr.number)-\(branch)").path
        _ = try await Shell.check("git", ["fetch", "origin", pr.headRefName], cwd: URL(fileURLWithPath: dir), timeout: 120)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await Shell.check("git", ["worktree", "add", "-b", branch, path, "origin/\(pr.headRefName)"], cwd: URL(fileURLWithPath: dir))
        let access: AccessLevel = readOnly ? .readOnly : (env == nil ? .fullAccess : .editFiles)
        var meta = SessionMeta(title: title, cwd: dir, access: access, branch: pr.headRefName, worktree: path)
        meta.reviewOf = reviewOf
        Workspace.shared.save(meta)
        let c = Workspace.shared.controller(meta.id)!
        c.loaded = true
        if show { Workspace.shared.select(meta.id) }
        c.draft = prompt; c.send()
        if show { AppDelegate.shared.showManager(pane: .sessions) }
        return c
    }
}

struct PullRequestsView: View {
    let center = PRCenter.shared
    @State private var repo = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Pull requests", subtitle: center.showInbox ? "What needs you in this repository" : center.repoDir.map { URL(fileURLWithPath: $0).lastPathComponent }) {
                HStack(spacing: 8) {
                    Segmented(options: [(false, "Repository"), (true, "Inbox")], selection: Bindable(center).showInbox)
                    AsyncButton { await center.refreshList() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.soft).help("Refresh").accessibilityLabel("Refresh")
                }
            }
            if center.showInbox { InboxView() }
            else if center.repoDir == nil {
                VStack(spacing: 8) {
                    Text("Choose a repository").font(.system(size: 15, weight: .semibold))
                    Text("Repositories come from your sessions. Start a session in a project first.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    if let first = center.repos().first { AsyncButton("Open \(first.name)") { await center.open(first) }.buttonStyle(Pill(kind: .primary)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    PRList().frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    PRDetail().frame(minWidth: 420)
                }
            }
        }
        .background(Theme.pane)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await center.refreshLive()
            }
        }
        .onAppear { Project.shared.ensureDefault(); if let r = Project.shared.current, r != center.currentRepo { Task { await center.open(r) } } else if center.selected != nil { Task { await center.refreshOpen() } } }
        .onChange(of: Project.shared.current) { _, r in if let r, r != center.currentRepo { Task { await center.open(r) } } }
        .sheet(isPresented: Bindable(center).showCreate) {
            if let dir = center.repoDir {
                CreatePRSheet(dir: dir, env: center.env) { n in
                    Task { await center.refreshList(); await center.select(n); CIWatcher.shared.nudge() }
                }
            }
        }
    }
}

struct PRList: View {
    let center = PRCenter.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(center.prs.count) open").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Create PR") { center.showCreate = true }.buttonStyle(Pill(kind: .primary))
            }.padding(10)
            Divider()
            if center.loading && center.prs.isEmpty { SkeletonList(rows: 5).padding(10); Spacer() }
            else if center.prs.isEmpty { Text("No open pull requests.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(20); Spacer() }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.prs) { pr in
                            Button { Task { await center.select(pr.number) } } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pr.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("#\(pr.number) · \(pr.headRefName)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                    HStack(spacing: 5) {
                                        if pr.isDraft { Badge(text: "Draft") }
                                        if center.isArmed(pr.number) || pr.autoMerge { Badge(text: "Auto-merge", kind: .ok) }
                                        if pr.reviewDecision == "CHANGES_REQUESTED" { Badge(text: "Changes requested", kind: .warn) }
                                        if pr.reviewDecision == "APPROVED" { Badge(text: "Approved", kind: .ok) }
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(center.selected == pr.number ? Theme.accentSoft : .clear).contentShape(Rectangle())
                            }.buttonStyle(.soft)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }.background(Theme.sidebar.opacity(0.4))
    }
}

struct PRDetail: View {
    let center = PRCenter.shared
    @State private var reviewNote = ""

    var body: some View {
        if let pr = center.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(pr)
                    steps(pr)
                    ReviewAndMerge(pr: pr)
                    if let b = pr.body.map(Stacks.withoutFooter), !b.isEmpty { Text(b).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card() }
                    SecurityPanel()
                    ChecksRow()
                    CommitsList()
                    DiffList()
                }.padding(20).frame(maxWidth: 900, alignment: .leading)
            }
        } else if center.selected != nil {
            SkeletonList(rows: 6).padding(20).frame(maxHeight: .infinity, alignment: .top)
        } else {
            Text("Select a pull request.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ pr: PullRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).font(.system(size: 17, weight: .semibold))
                Text("#\(pr.number) · \(pr.headRefName) → \(pr.baseRefName) · \(pr.author?.login ?? "")").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = pr.additions, let d = pr.deletions { Text("+\(a) −\(d)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
            Button("Open on GitHub") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }.buttonStyle(Pill(kind: .plain))
        }
    }

    private func steps(_ pr: PullRequest) -> some View {
        let reviewed = pr.reviewDecision == "APPROVED"
        let ready = center.gate?.ready == true
        return HStack(spacing: 6) {
            step("Opened", done: true)
            step("Checks", done: !center.checks.isEmpty && center.checks.allSatisfy(\.passed))
            step("Security scan", done: center.scan.map { !$0.blocksMerge } ?? false)
            step("Review", done: reviewed)
            step("Merge", done: ready, current: ready)
        }
    }

    private func step(_ t: String, done: Bool, current: Bool = false) -> some View {
        HStack(spacing: 5) { Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 11)); Text(t).font(.system(size: 12)) }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(done ? Theme.ok : .secondary)
            .background(current ? Theme.accentSoft : Theme.fill, in: Capsule())
    }
}

struct ChecksRow: View {
    let center = PRCenter.shared
    var body: some View {
        if !center.checks.isEmpty {
            HStack(spacing: 6) {
                Text("Checks").font(.system(size: 12, weight: .semibold))
                ForEach(center.checks) { c in
                    Badge(text: c.name, kind: c.passed ? .ok : (c.failed ? .danger : .warn))
                }
                Spacer()
            }
        }
    }
}

struct CommitsList: View {
    let center = PRCenter.shared
    var body: some View {
        if !center.commits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Commits (\(center.commits.count))").font(.system(size: 12, weight: .semibold))
                ForEach(center.commits) { c in
                    HStack(spacing: 8) {
                        Text(c.sha).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(c.subject).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(c.when).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
}

struct SecurityPanel: View {
    let center = PRCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Security scan").font(.system(size: 13, weight: .semibold))
                if center.scanning { ProgressView().controlSize(.small) }
                else if let s = center.scan { Badge(text: s.blocksMerge ? "\(s.confirmed.count) confirmed" : "Clean", kind: s.blocksMerge ? .warn : .ok) }
                else { Badge(text: "Not run") }
                Spacer()
                AsyncButton(center.scan == nil ? "Run scan" : "Re-scan") { await center.runScan() }.buttonStyle(Pill(kind: .plain)).disabled(center.scanning || !SecurityCage.isAvailable(configured: Prefs.shared.securityCagePath))
            }.padding(12)
            if !SecurityCage.isAvailable(configured: Prefs.shared.securityCagePath) {
                Divider(); Text(Shell.find("node") == nil ? "The scan needs Node.js. Install it with: brew install node" : SecurityCage.setupHint).font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }
            if let s = center.scan {
                ForEach(s.findings) { f in
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(f.title).font(.system(size: 12.5, weight: .medium)); Badge(text: f.confirmed ? "Proven" : "Lead", kind: f.confirmed ? .warn : .neutral) }
                            if !f.detail.isEmpty { Text(f.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(4) }
                        }
                        Spacer()
                        if f.confirmed {
                            AsyncButton("Fix it") { await center.startSession(prompt: SecurityCage.fixPrompt(f), title: "Fix: \(f.title)", readOnly: false) }.buttonStyle(Pill(kind: .primary))
                        }
                    }.padding(12)
                }
                Divider()
                HStack {
                    Text(center.scanLog.last ?? "Scans the branch as data. With a local model and Docker running, findings are proven in a sandbox.").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    AsyncButton("Post to PR") { await center.post(comment: "### Security scan\n" + s.report.prefix(3000)) }.buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(Theme.accent)
                }.padding(12)
            } else if center.scanning, let l = center.scanLog.last {
                Divider(); Text(l).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).padding(12)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

struct ReviewAndMerge: View {
    let pr: PullRequest
    let center = PRCenter.shared

    @State private var choosing = false
    @State private var readOnly = false

    private static let styles: [(MergeMethod, String)] = [(.merge, "Create a merge commit"), (.squash, "Squash and merge"), (.rebase, "Rebase and merge")]

    var body: some View {
        VStack(spacing: 12) {
            review
            mergeBox
        }
    }

    private var review: some View {
        SettingRow("Review", "Ask an agent to review the change in a fresh session with Full access (or read only, if you prefer), or review it yourself.", separator: false) {
            HStack(spacing: 6) {
                Toggle("Read only", isOn: $readOnly).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12))
                Button("Review with Claude") {
                    Task { await center.startSession(prompt: "Review pull request #\(pr.number) (\(pr.title)). Run `git diff origin/\(pr.baseRefName)...HEAD` and report correctness bugs, risky changes and missing tests. Be specific with file and line.", title: "Review #\(pr.number)", readOnly: readOnly) }
                }.buttonStyle(Pill(kind: .plain))
                let own = pr.author?.login.caseInsensitiveCompare(AppModel.shared.github?.login ?? "") == .orderedSame   // GitHub refuses both on your own PR
                AsyncButton("Approve") { await center.review(.approve) }.buttonStyle(Pill(kind: .plain)).disabled(own).help(own ? "You can't approve your own pull request." : "")
                AsyncButton("Request changes") { await center.review(.requestChanges, body: "Please see the review notes.") }.buttonStyle(Pill(kind: .plain)).disabled(own).help(own ? "You can't request changes on your own pull request." : "")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var styleList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.styles, id: \.0) { m, title in
                Button { center.method = m; choosing = false } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").opacity(center.method == m ? 1 : 0).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(title).font(.system(size: 12.5, weight: .medium))
                                if center.recommended?.method == m { Badge(text: "Recommended", kind: .ok) }
                            }
                            Text(center.allowed.contains(m) ? Self.blurb(m, base: pr.baseRefName) : "This repository does not allow it.").font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.soft).disabled(!center.allowed.contains(m))
            }
        }.padding(6).frame(width: 320)
    }

    /// Like GitHub's merge box: what is blocking the merge, then one button whose arrow picks the merge style.
    @ViewBuilder private var mergeBox: some View {
        if pr.isOpen {
            let gate = center.gate
            let ready = gate?.ready == true
            let armed = center.isArmed(pr.number)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(ready ? Theme.ok : Theme.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ready ? "Ready to merge" : "Merging is blocked").font(.system(size: 13.5, weight: .semibold))
                        if ready { Text("Every rule passes.").font(.system(size: 12)).foregroundStyle(.secondary) }
                        else { ForEach(gate?.reasons ?? [], id: \.self) { Text("• " + $0).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                    }
                    Spacer(minLength: 0)
                }.padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 0) {
                        AsyncButton { await center.mergeNow() } label: { Text(Self.label(center.method)).frame(minWidth: 130) }
                            .buttonStyle(MergeSplit(position: .leading, ready: ready)).disabled(!ready)
                        Button { choosing = true } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 18)
                        }
                        .buttonStyle(MergeSplit(position: .trailing, ready: ready))
                        .popover(isPresented: $choosing, arrowEdge: .bottom) { styleList }
                    }
                    Text(Self.blurb(center.method, base: pr.baseRefName)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let rec = center.recommended, rec.method != center.method {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label("Recommended: \(Self.label(rec.method)). \(rec.reason)", systemImage: "lightbulb").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Use it") { center.method = rec.method }.buttonStyle(Pill(kind: .plain))
                        }
                    }
                    if !center.duplicates.isEmpty { duplicateWarning(base: pr.baseRefName) }
                    Toggle(isOn: Binding(get: { armed }, set: { center.setArmed($0, pr.number) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Merge automatically when ready").font(.system(size: 12.5))
                            Text("Merges as soon as every rule passes, then deletes the branch. CPilot checks once a minute while this is on.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.checkbox)
                }.padding(14)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ready ? Theme.ok.opacity(0.5) : Theme.hairline))
        }
    }

    /// The same change would land on the base branch twice under one name: say so, and make the fix one step away.
    private func duplicateWarning(base: String) -> some View {
        @Bindable var c = center
        return VStack(alignment: .leading, spacing: 8) {
            Label(center.duplicates.contains { !$0.sameChange } ? "\(base) already has a commit with this title" : "\(base) already has this change", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.warn)
            ForEach(center.duplicates.prefix(3)) { d in
                Text(d.sameChange ? "commit \(d.mine)  \(d.subject)  ←  same change is already on \(base)"
                                  : "\(d.onBase)  \(d.subject)  ←  \(d.mine == "title" ? "this pull request's title" : "commit \(d.mine)")")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let commit = center.duplicates.first(where: { $0.mine != "title" }) {
                Text("This pull request still carries commit \(commit.mine), which \(base) already has. That usually means a pull request below it in the stack was merged and this one was not rebased since. A new title will not fix that; restacking drops the commit that is already merged.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AsyncButton { await center.restackAndPush() } label: { BusyLabel(title: "Restack onto \(base) and push", busyTitle: "Restacking…", busy: center.restacking) }
                    .buttonStyle(Pill(kind: .primary)).disabled(center.restacking)
                Text("Or, if the pull request really has grown, give it a title that describes all of it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("The title is the same as a commit already on \(base). Give it a title that describes this change, so \(base) does not end up with two commits of one name.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Pull request title", text: $c.titleDraft).textFieldStyle(CPField())
                AsyncButton("Suggest") { await center.suggestTitle() }.buttonStyle(Pill(kind: .plain))
                AsyncButton("Update title") { await center.retitle(center.titleDraft) }.buttonStyle(Pill(kind: .primary))
                    .disabled(center.titleDraft.trimmingCharacters(in: .whitespaces).isEmpty || center.titleDraft == pr.title)
            }
        }.padding(10).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.warn.opacity(0.4)))
    }

    static func label(_ m: MergeMethod) -> String { styles.first { $0.0 == m }?.1 ?? "Merge" }
    static func blurb(_ m: MergeMethod, base: String) -> String {
        switch m {
        case .merge: "All commits from this branch are added to \(base) with a merge commit."
        case .squash: "The commits from this branch are combined into one commit on \(base)."
        case .rebase: "The commits from this branch are added to \(base) one by one, without a merge commit."
        }
    }
}

/// One half of a split button: the left half runs the action, the right half opens the menu.
private struct MergeSplit: ButtonStyle {
    enum Position { case leading, trailing }
    let position: Position
    let ready: Bool

    static func shape(_ position: Position) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: position == .leading ? 8 : 0, bottomLeadingRadius: position == .leading ? 8 : 0,
                               bottomTrailingRadius: position == .trailing ? 8 : 0, topTrailingRadius: position == .trailing ? 8 : 0)
    }

    func makeBody(configuration: Configuration) -> some View {
        let on = ready
        let shape = Self.shape(position)
        return configuration.label.font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, position == .leading ? 14 : 10).frame(height: 32)
            .foregroundStyle(on ? Theme.onAccent : Color.secondary.opacity(0.75))
            .background(on ? Theme.ok.opacity(configuration.isPressed ? 0.8 : 1) : Theme.fill, in: shape)
            .overlay(alignment: .leading) { if position == .trailing { Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1) } }
    }
}

struct DiffList: View {
    let center = PRCenter.shared
    @State private var expanded: Set<String> = []
    @State private var seeded: String?
    @State private var listOpen = true

    private var visible: [DiffFile] {
        center.files.filter { center.fileFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(center.fileFilter) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(center.files.count) files changed").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Expand all") { expanded = Set(center.files.map(\.path)) }.buttonStyle(.soft).foregroundStyle(Theme.accent).font(.system(size: 12))
                    Button("Collapse all") { expanded = [] }.buttonStyle(.soft).foregroundStyle(Theme.accent).font(.system(size: 12))
                    SearchBox(prompt: "Filter files", text: Bindable(center).fileFilter).frame(width: 180)
                }
                fileList(proxy)
                ForEach(visible) { f in
                    DiffFileView(file: f, collapsed: !expanded.contains(f.path)) {
                        if expanded.contains(f.path) { expanded.remove(f.path) } else { expanded.insert(f.path) }
                    }.id(f.path)
                }
            }
            .onAppear(perform: seed)
            .onChange(of: center.files.first?.path) { seed() }
        }
    }

    /// A new pull request starts with only its first file open.
    private func seed() {
        let key = center.files.first?.path
        guard key != seeded else { return }
        seeded = key
        expanded = key.map { [$0] } ?? []
    }

    private func fileList(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { listOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: listOpen ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Files").font(.system(size: 12, weight: .medium))
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.soft)
            if listOpen {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { f in
                            Button {
                                expanded.insert(f.path)
                                withAnimation { proxy.scrollTo(f.path, anchor: .top) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: expanded.contains(f.path) ? "doc.text.fill" : "doc.text").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    Text(f.path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                    if f.isNew { Badge(text: "New", kind: .ok) }
                                    if f.isDeleted { Badge(text: "Deleted", kind: .danger) }
                                    Spacer()
                                    Text("+\(f.additions)").foregroundStyle(Theme.ok)
                                    Text("−\(f.deletions)").foregroundStyle(Theme.danger)
                                }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 3).contentShape(Rectangle())
                            }.buttonStyle(.soft)
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }
}


/// Pull requests in the chosen repository that need you: review requested, and yours.
@MainActor @Observable
final class InboxCenter {
    static let shared = InboxCenter()
    var review: [GitHub.InboxItem] = []
    var mine: [GitHub.InboxItem] = []
    var loading = false
    private var local: [String: PRCenter.Repo] = [:]

    private var cache: [String: (review: [GitHub.InboxItem], mine: [GitHub.InboxItem], at: Date)] = [:]
    private var localAt: Date?

    /// Shows the repository's cached inbox at once; fetches only when it is older than 30 seconds, or when `force` is set.
    func load(force: Bool = false) async {
        guard let dir = PRCenter.shared.repoDir, let slug = await Git.info(dir)?.remote else { review = []; mine = []; return }
        if let c = cache[slug] {
            review = c.review; mine = c.mine
            if !force, Date().timeIntervalSince(c.at) < 30 { return }
        } else { review = []; mine = [] }
        loading = true; defer { loading = false }
        async let mapping: Void = refreshLocal()
        let r = await GitHub.inbox(repo: slug)
        cache[slug] = (r.reviewRequested, r.mine, .now)
        if PRCenter.shared.repoDir == dir { review = r.reviewRequested; mine = r.mine }
        await mapping
    }

    /// Which repositories are on this Mac, so a click can open the full review screen. Looked up in parallel and kept for a minute.
    private func refreshLocal() async {
        if let t = localAt, Date().timeIntervalSince(t) < 60 { return }
        let repos = PRCenter.shared.repos().filter { $0.environment == nil }
        let pairs = await withTaskGroup(of: (String, PRCenter.Repo)?.self) { group in
            for repo in repos { group.addTask { await Git.info(repo.dir)?.remote.map { ($0, repo) } } }
            var out: [(String, PRCenter.Repo)] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
        local = Dictionary(pairs, uniquingKeysWith: { a, _ in a }); localAt = .now
    }

    func repo(for item: GitHub.InboxItem) -> PRCenter.Repo? { local[item.repository.nameWithOwner] }

    func open(_ item: GitHub.InboxItem) async {
        if let r = repo(for: item) {
            await PRCenter.shared.open(r)
            await PRCenter.shared.select(item.number)
            PRCenter.shared.showInbox = false
        } else if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
    }

    func clone(_ item: GitHub.InboxItem) async {
        do {
            try? FileManager.default.createDirectory(atPath: Prefs.shared.cloneFolder, withIntermediateDirectories: true)
            let dir = try await GitHub.clone(item.repository.nameWithOwner, into: Prefs.shared.cloneFolder)
            local[item.repository.nameWithOwner] = PRCenter.Repo(dir: dir, environment: nil)
            AppModel.shared.show("Cloned \(item.repository.nameWithOwner)")
        } catch { AppModel.shared.failQuietly(error, action: "Clone") }
    }
}

struct InboxView: View {
    let center = InboxCenter.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if center.loading && center.review.isEmpty && center.mine.isEmpty { SkeletonList(rows: 5) }
                section("Review requested", center.review, empty: "Nothing is waiting for your review.")
                section("Yours", center.mine, empty: "You have no open pull requests.")
            }.padding(22).frame(maxWidth: 860, alignment: .leading)
        }
        .task(id: PRCenter.shared.repoDir) { if !AppModel.shared.demo { await center.load() } }
    }

    @ViewBuilder private func section(_ title: String, _ items: [GitHub.InboxItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { SectionLabel(title); Badge(text: "\(items.count)"); Spacer(); if title == "Yours" { AsyncButton { await center.load(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.soft).help("Refresh") } }.padding(.leading, 4)
            VStack(spacing: 0) {
                if items.isEmpty { Text(empty).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { Divider().opacity(0.6) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(it.repository.nameWithOwner) #\(it.number) · \(it.author?.login ?? "")").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if it.isDraft == true { Badge(text: "Draft") }
                        if center.repo(for: it) == nil { AsyncButton("Clone") { await center.clone(it) }.buttonStyle(Pill(kind: .plain)) }
                        AsyncButton(center.repo(for: it) == nil ? "Open on GitHub" : "Review") { await center.open(it) }.buttonStyle(Pill(kind: center.repo(for: it) == nil ? .plain : .primary))
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                }
            }.background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }
}
