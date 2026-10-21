// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Pull request state for the screen: list, detail, diff, checks, security scan and the merge gate.
@MainActor @Observable
final class PRCenter {
    static let shared = PRCenter()
    var repoDir: String?
    var prs: [PullRequest] = []
    var selected: Int?
    var detail: PullRequest?
    var files: [DiffFile] = []
    var checks: [PullRequest.Check] = []
    var scan: SecurityResult?
    var scanning = false
    var scanLog: [String] = []
    var loading = false
    var error: String?
    var method: MergeMethod = .squash
    var fileFilter = ""
    var showCreate = false
    /// Pull requests CPilot merges by itself the moment every rule passes: "owner/repo#number" -> repo folder.
    var armed: [String: String] = UserDefaults.standard.dictionary(forKey: "armedMerges") as? [String: String] ?? [:]
    private var scans: [String: SecurityResult] = [:]     // by head branch + number, so a re-open does not rescan
    private var watcher: Task<Void, Never>?

    var gate: MergeGate? {
        guard let pr = detail else { return nil }
        return MergeGate.evaluate(pr: pr, checks: checks, scan: scan, requireScan: Prefs.shared.securityScanOnPR)
    }

    func repos() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in Workspace.shared.sessions where !seen.contains(m.cwd) { seen.insert(m.cwd); out.append(m.cwd) }
        return out
    }

    func open(repo: String) async {
        repoDir = repo; selected = nil; detail = nil; files = []; error = nil
        await refreshList()
    }

    func refreshList() async {
        guard let dir = repoDir else { return }
        loading = true; defer { loading = false }
        do { prs = try await GitHub.list(in: dir, state: "open") } catch { self.error = UserError.message(for: error, action: "Load pull requests") }
    }

    func select(_ n: Int) async {
        guard let dir = repoDir else { return }
        selected = n; detail = nil; files = []; checks = []; scan = nil; scanLog = []
        do {
            async let pr = GitHub.view(n, in: dir)
            async let diff = GitHub.diff(n, in: dir)
            async let chk = GitHub.checks(n, in: dir)
            let (p, d, c) = try await (pr, diff, chk)
            guard selected == n else { return }
            detail = p; files = DiffParser.parse(d); checks = c
            scan = scans["\(dir)#\(n)#\(p.headRefName)"]
        } catch { self.error = UserError.message(for: error, action: "Load the pull request") }
    }

    func runScan() async {
        guard let dir = repoDir, let pr = detail else { return }
        scanning = true; scanLog = []; defer { scanning = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cpilot-scan-\(pr.number)-\(UUID().uuidString.prefix(6))").path
        do {
            _ = try await Shell.check("git", ["fetch", "origin", "pull/\(pr.number)/head"], cwd: URL(fileURLWithPath: dir), timeout: 120)
            try await Shell.check("git", ["worktree", "add", "--detach", tmp, "FETCH_HEAD"], cwd: URL(fileURLWithPath: dir))
            let prove = await SecurityCage.dockerRunning()
            if !prove { scanLog.append("Docker is not running, so findings are listed but not proven.") }
            let result = try await SecurityCage.scan(folder: tmp, prove: prove) { [weak self] line in Task { @MainActor in self?.scanLog.append(line) } }
            scan = result; scans["\(dir)#\(pr.number)#\(pr.headRefName)"] = result
        } catch { self.error = UserError.message(for: error, action: "Run the security scan") }
        await Git.removeWorktree(repo: dir, path: tmp)
    }

    func review(_ action: ReviewAction, body: String = "") async {
        guard let dir = repoDir, let n = selected else { return }
        do { try await GitHub.review(n, action: action, body: body, in: dir); AppModel.shared.show(action == .approve ? "Approved" : "Review sent"); await select(n) }
        catch { self.error = UserError.message(for: error, action: "Send the review") }
    }

    func mergeNow() async {
        guard let dir = repoDir, let n = selected else { return }
        do {
            try await GitHub.merge(n, method: method, auto: false, in: dir)
            AppModel.shared.show("Merged #\(n)"); disarm(n)
            await refreshList(); selected = nil; detail = nil
        } catch { self.error = UserError.message(for: error, action: "Merge") }
    }

    func post(comment: String) async {
        guard let dir = repoDir, let n = selected else { return }
        do { try await GitHub.comment(n, body: comment, in: dir); AppModel.shared.show("Comment posted") } catch { self.error = UserError.message(for: error, action: "Post the comment") }
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
            var result = scans["\(dir)#\(n)#\(pr.headRefName)"]
            if result == nil, Prefs.shared.securityScanOnPR, let r = await scanQuietly(pr, dir: dir) { result = r; scans["\(dir)#\(n)#\(pr.headRefName)"] = r }
            let gate = MergeGate.evaluate(pr: pr, checks: chk, scan: result, requireScan: Prefs.shared.securityScanOnPR)
            if gate.ready {
                do {
                    try await GitHub.merge(n, method: method, auto: false, in: dir)
                    armed[k] = nil; persistArmed()
                    AppModel.shared.notify("Merged #\(n)", body: pr.title)
                } catch { AppLog.error(error, context: "auto-merge #\(n)") }
            }
        }
        if armed.isEmpty { watcher?.cancel(); watcher = nil }
        await refreshList()
    }

    private func scanQuietly(_ pr: PullRequest, dir: String) async -> SecurityResult? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cpilot-scan-\(pr.number)-\(UUID().uuidString.prefix(6))").path
        defer { Task { await Git.removeWorktree(repo: dir, path: tmp) } }
        guard (try? await Shell.check("git", ["fetch", "origin", "pull/\(pr.number)/head"], cwd: URL(fileURLWithPath: dir), timeout: 120)) != nil,
              (try? await Shell.check("git", ["worktree", "add", "--detach", tmp, "FETCH_HEAD"], cwd: URL(fileURLWithPath: dir))) != nil else { return nil }
        return try? await SecurityCage.scan(folder: tmp, prove: await SecurityCage.dockerRunning()) { _ in }
    }

    /// Starts a session on the pull request's branch, in its own worktree, asking the agent to review or to fix a finding.
    func startSession(prompt: String, title: String, readOnly: Bool) async {
        guard let dir = repoDir, let pr = detail else { return }
        let branch = "review-\(pr.number)-\(Int(Date().timeIntervalSince1970) % 100000)"
        let path = AppPaths().root.appendingPathComponent("worktrees/pr-\(pr.number)-\(branch)").path
        do {
            _ = try await Shell.check("git", ["fetch", "origin", pr.headRefName], cwd: URL(fileURLWithPath: dir), timeout: 120)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try await Shell.check("git", ["worktree", "add", "-b", branch, path, "origin/\(pr.headRefName)"], cwd: URL(fileURLWithPath: dir))
            var meta = SessionMeta(title: title, cwd: dir, access: readOnly ? .readOnly : .editFiles, branch: pr.headRefName, worktree: path)
            meta.access = readOnly ? .readOnly : .editFiles
            Workspace.shared.save(meta)
            let c = Workspace.shared.controller(meta.id)!
            c.loaded = true
            Workspace.shared.select(meta.id)
            c.draft = prompt; c.send()
            AppDelegate.shared.showManager(pane: .sessions)
        } catch { self.error = UserError.message(for: error, action: "Start the session") }
    }
}

struct PullRequestsView: View {
    let center = PRCenter.shared
    @State private var repo = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Pull requests", subtitle: center.repoDir.map { URL(fileURLWithPath: $0).lastPathComponent }) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(center.repos(), id: \.self) { r in Button(URL(fileURLWithPath: r).lastPathComponent) { Task { await center.open(repo: r) } } }
                    } label: { Label("Repository", systemImage: "folder") }.menuStyle(.borderlessButton).fixedSize()
                    Button { Task { await center.refreshList() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
                }
            }
            if center.repoDir == nil {
                VStack(spacing: 8) {
                    Text("Choose a repository").font(.system(size: 15, weight: .semibold))
                    Text("Repositories come from your sessions. Start a session in a project first.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    if let first = center.repos().first { Button("Open \(URL(fileURLWithPath: first).lastPathComponent)") { Task { await center.open(repo: first) } }.buttonStyle(Pill(kind: .primary)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    PRList().frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    PRDetail().frame(minWidth: 420)
                }
            }
        }
        .background(Theme.pane)
        .onAppear {
            if center.repoDir == nil, let first = center.repos().first { Task { await center.open(repo: first) } }
        }
        .sheet(isPresented: Bindable(center).showCreate) {
            if let dir = center.repoDir {
                CreatePRSheet(dir: dir) { n in
                    Task { await center.refreshList(); await center.select(n) }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { center.error != nil }, set: { if !$0 { center.error = nil } })) {
            Button("OK") { center.error = nil }
        } message: { Text(center.error ?? "") }
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
                            }.buttonStyle(.plain)
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
                    if let b = pr.body, !b.isEmpty { Text(b).font(.system(size: 12.5)).foregroundStyle(.secondary).card() }
                    SecurityPanel()
                    ChecksRow()
                    DiffList()
                    ReviewAndMerge(pr: pr)
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
                Button(center.scan == nil ? "Run scan" : "Re-scan") { Task { await center.runScan() } }.buttonStyle(Pill(kind: .plain)).disabled(center.scanning || !SecurityCage.isAvailable())
            }.padding(12)
            if !SecurityCage.isAvailable() {
                Divider(); Text("The scan needs Node.js. Install it with: brew install node").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
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
                            Button("Fix it") { Task { await center.startSession(prompt: SecurityCage.fixPrompt(f), title: "Fix: \(f.title)", readOnly: false) } }.buttonStyle(Pill(kind: .primary))
                        }
                    }.padding(12)
                }
                Divider()
                HStack {
                    Text(center.scanLog.last ?? "Scans the branch as data, offline. Findings are proven in Docker when it is running.").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Post to PR") { Task { await center.post(comment: "### Security scan\n" + s.report.prefix(3000)) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
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
    var body: some View {
        let gate = center.gate
        @Bindable var c = center
        VStack(spacing: 0) {
            SettingRow("Review", "Ask an agent to read the change in a fresh read-only session, or review it yourself.") {
                HStack(spacing: 6) {
                    Button("Review with Claude") {
                        Task { await center.startSession(prompt: "Review pull request #\(pr.number) (\(pr.title)). Run `git diff origin/\(pr.baseRefName)...HEAD` and report correctness bugs, risky changes and missing tests. Be specific with file and line.", title: "Review #\(pr.number)", readOnly: true) }
                    }.buttonStyle(Pill(kind: .plain))
                    Button("Approve") { Task { await center.review(.approve) } }.buttonStyle(Pill(kind: .plain))
                    Button("Request changes") { Task { await center.review(.requestChanges, body: "Please see the review notes.") } }.buttonStyle(Pill(kind: .plain))
                }
            }
            SettingRow("Merge automatically", "Merges by itself as soon as every rule passes, then deletes the branch. CPilot checks once a minute while this is on.") {
                Toggle("", isOn: Binding(get: { center.isArmed(pr.number) }, set: { center.setArmed($0, pr.number) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            SettingRow("Merge style", "How the commits land on \(pr.baseRefName).") {
                Segmented(options: [(MergeMethod.squash, "Squash"), (.merge, "Merge"), (.rebase, "Rebase")], selection: $c.method)
            }
            SettingRow(gate?.ready == true ? "Ready to merge" : "Waiting", gate?.reasons.joined(separator: " ") ?? "") {
                Button("Merge now") { Task { await center.mergeNow() } }.buttonStyle(Pill(kind: .primary)).disabled(gate?.ready != true)
            }
        }
        .padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

struct DiffList: View {
    let center = PRCenter.shared
    @State private var collapsed: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(center.files.count) files changed").font(.system(size: 13, weight: .semibold))
                Spacer()
                SearchBox(prompt: "Filter files", text: Bindable(center).fileFilter).frame(width: 180)
            }
            ForEach(center.files.filter { center.fileFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(center.fileFilter) }) { f in
                DiffFileView(file: f, collapsed: collapsed.contains(f.path)) { if collapsed.contains(f.path) { collapsed.remove(f.path) } else { collapsed.insert(f.path) } }
            }
        }
    }
}
