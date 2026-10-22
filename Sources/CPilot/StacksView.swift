// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Stacked pull requests: small branches that build on each other, each with its own pull request.
/// CPilot keeps them in order (restack), sends them to GitHub (submit) and merges them from the bottom.
@MainActor @Observable
final class StackCenter {
    static let shared = StackCenter()
    var repo: PRCenter.Repo?
    var stacks: [Stack] = []
    /// Check results of each stack's bottom open pull request, by number.
    var checks: [Int: [PullRequest.Check]] = [:]
    var loading = false
    var busy: String?
    var error: String?
    var conflict: (branch: String, files: [String])?
    var notice: String?
    var method: MergeMethod = .squash
    /// Open pull requests GitHub's rules refuse to merge (a ruleset or branch protection), even though CPilot's own checks pass.
    /// Auto-merge leaves them alone until GitHub's verdict changes; otherwise it would fail the same way every minute.
    var policyBlocked: Set<Int> = []
    var env: EnvironmentConfig? { Workspace.shared.environment(repo?.environment) }

    /// Repositories whose stacks CPilot merges by itself, bottom first, whenever the merge rules pass. Checked once a minute while any is armed.
    var armed: [String: String] = UserDefaults.standard.dictionary(forKey: "armedStacks") as? [String: String] ?? [:]
    private var watcher: Task<Void, Never>?

    func isArmed(_ r: PRCenter.Repo) -> Bool { armed[r.dir + "|" + (r.environment ?? "")] != nil }

    func arm(repo r: PRCenter.Repo, on: Bool = true) {
        let key = r.dir + "|" + (r.environment ?? "")
        if on { armed[key] = r.environment ?? "" } else { armed[key] = nil }
        UserDefaults.standard.set(armed, forKey: "armedStacks")
        startWatcher()
    }

    func startWatcher() {
        watcher?.cancel(); watcher = nil
        guard !armed.isEmpty else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.mergeArmed()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func mergeArmed() async {
        for (key, envId) in armed {
            let dir = String(key.split(separator: "|", omittingEmptySubsequences: false).first ?? "")
            let environment = Workspace.shared.environment(envId.isEmpty ? nil : envId)
            let open: Bool = await Exec.with(environment) {
                let host = LiveStackHost(dir: dir)
                guard let stack = await Stacks.load(in: dir, host: host).first(where: { $0.branches.contains { !$0.isMerged && $0.prState == "OPEN" } }),
                      let bottom = stack.branches.first(where: { !$0.isMerged && $0.prState == "OPEN" }), let n = bottom.pr else { return false }
                if policyBlocked.contains(n) { if bottom.mergeState == "BLOCKED" { return true } else { policyBlocked.remove(n) } }
                let gate = await PRCenter.shared.gateFor(n, dir: dir)
                guard gate.ready else { return true }
                do {
                    _ = try await Stacks.mergeBottom(stack, in: dir, host: host, method: method)
                    _ = try await Stacks.sync(in: dir, host: host)
                    if let fresh = await Stacks.load(in: dir, host: host).first(where: { st in st.branches.contains { !$0.isMerged } }) { _ = try await Stacks.submit(fresh, in: dir, host: host) }
                    AppModel.shared.notify("Merged #\(n)", body: stack.branches.last?.title ?? "")
                } catch {
                    if GitHub.isPolicyBlocked(error) {
                        policyBlocked.insert(n)
                        AppLog.info("auto-merge stack: GitHub's rules block #\(n); waiting for that to change")
                        AppModel.shared.notify("#\(n) can't merge", body: "Its checks pass, but GitHub's rules for the repository refuse the merge.")
                    } else { AppLog.error(error, context: "auto-merge stack") }
                }
                return true
            }
            if !open { armed[key] = nil; UserDefaults.standard.set(armed, forKey: "armedStacks") }
        }
        if armed.isEmpty { watcher?.cancel(); watcher = nil }
    }

    // MARK: Cache

    /// What was last read for a repository. Kept per repository and on disk, so a screen opens with the last known stacks while the new read runs.
    private struct Snapshot: Codable { var stacks: [Stack]; var checks: [Int: [PullRequest.Check]]; var at: Date }
    private static let freshFor: TimeInterval = 30
    private static var cacheURL: URL { AppPaths().root.appendingPathComponent("stacks-cache.json") }
    private var cache: [String: Snapshot] = {
        guard let data = try? Data(contentsOf: StackCenter.cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Snapshot].self, from: data)) ?? [:]
    }()
    private(set) var loadedAt: Date?

    private func cacheKey(_ r: PRCenter.Repo) -> String { r.dir + "|" + (r.environment ?? "") }

    private func store(_ r: PRCenter.Repo) {
        let now = Date()
        cache[cacheKey(r)] = Snapshot(stacks: stacks, checks: checks, at: now); loadedAt = now
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }

    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) > Self.freshFor } ?? true }

    /// Shows what is known right away. Reads again only when that is older than 30 seconds, or when `force` says something changed.
    func open(_ r: PRCenter.Repo, force: Bool = false) async {
        if r != repo {
            repo = r; conflict = nil; error = nil; notice = nil
            let c = cache[cacheKey(r)]
            stacks = c?.stacks ?? []; checks = c?.checks ?? [:]; loadedAt = c?.at
        }
        Project.shared.current = r
        if force || isStale { await refresh() }
    }

    /// Two steps, so the screen is useful early: the stacks and their pull requests as they are now, then the fetch and the check results.
    func refresh(manual: Bool = false) async {
        guard let r = repo, !loading else { return }
        loading = true; defer { loading = false }
        let quick = await Exec.with(env) { await Stacks.load(in: r.dir, host: LiveStackHost(dir: r.dir)) }
        guard repo == r else { return }
        if !quick.isEmpty || stacks.isEmpty { stacks = quick; noteBlocked() }
        let (loaded, results) = await Exec.with(env) { () -> ([Stack], [Int: [PullRequest.Check]]) in
            await Stacks.fetch(in: r.dir)
            let list = await Stacks.load(in: r.dir, host: LiveStackHost(dir: r.dir))
            var results: [Int: [PullRequest.Check]] = [:]
            for n in list.compactMap({ $0.bottomOpen?.pr }) { results[n] = await GitHub.checks(n, in: r.dir) }
            return (list, results)
        }
        guard repo == r else { return }
        stacks = loaded; checks = results; noteBlocked(); store(r)
        // A conflict is whatever the repository says it is: a rebase stopped part-way. It survives a restart, and it clears once resolved or aborted.
        conflict = await Exec.with(env) { await Stacks.pendingConflict(in: r.dir) }.map { ($0.branch, $0.files) }
        if manual { AppModel.shared.show(stacks.isEmpty ? "Refreshed. No stacks in this repository." : "Refreshed \(stacks.count) stack\(stacks.count == 1 ? "" : "s").", error: false) }
    }

    /// A pull request GitHub no longer calls blocked is free to try again.
    private func noteBlocked() {
        let blocked = Set(stacks.compactMap { $0.bottomOpen }.filter { $0.mergeState == "BLOCKED" }.compactMap(\.pr))
        policyBlocked.formIntersection(blocked)
    }

    /// Runs one stack operation with a visible label, on the right machine, and turns failures into plain messages.
    func run(_ label: String, _ body: @escaping (String, StackHost) async throws -> String?) async {
        guard let r = repo, busy == nil else { return }
        busy = label; error = nil; notice = nil
        defer { busy = nil }
        do {
            let msg = try await Exec.with(env) { try await body(r.dir, LiveStackHost(dir: r.dir)) }
            notice = msg
        } catch let e as StackError {
            if case .conflict = e { /* shown from the repository's real state by refresh() below */ } else { error = e.localizedDescription }
        } catch { self.error = AppModel.shared.capture(error, action: label) }
        await refresh()
        // Merging and restacking change the pull requests' branches. A pull request already open on the other screen was judged before that.
        await PRCenter.shared.refreshOpen()
    }

    func restack(_ s: Stack) async {
        await run("Restacking") { dir, _ in
            let r = try await Stacks.restack(s, in: dir)
            if case .restacked(let m) = r { return "Restacked \(m.joined(separator: ", "))." }
            return "Already up to date."
        }
    }

    func submit(_ s: Stack) async {
        await run("Submitting") { dir, host in
            let n = try await Stacks.submit(s, in: dir, host: host)
            return "Submitted \(n.count) pull request\(n.count == 1 ? "" : "s")."
        }
    }

    func sync() async {
        await run("Syncing") { dir, host in
            let r = try await Stacks.sync(in: dir, host: host)
            if case .restacked(let m) = r { return "Synced and restacked \(m.joined(separator: ", "))." }
            return "Synced. Everything is up to date."
        }
    }

    /// Merges the lowest pull request if every rule passes, then restacks and resubmits the rest.
    /// `admin` merges past the repository's rules; the card only offers it after a warning the user confirms.
    func mergeBottom(_ s: Stack, admin: Bool = false) async {
        await run("Merging") { [method] dir, host in
            let n = try await self.mergeOne(s, admin: admin, method: method, dir: dir, host: host)
            return "Merged #\(n). The next pull request is waiting for its checks."
        }
    }

    /// Waits for `n`'s checks to finish, and stops with a plain message at the first other thing that is not ready.
    private func waitUntilReady(_ n: Int, dir: String, merged: [Int]) async throws {
        var waited = 0
        while true {
            let gate = await PRCenter.shared.gateFor(n, dir: dir)
            if gate.ready { return }
            guard gate.reasons == ["Checks are still running."], waited < 900 else {
                throw StackError.message((merged.isEmpty ? "" : "Merged \(merged.map { "#\($0)" }.joined(separator: ", ")), then stopped. ") + "#\(n) is not ready: " + gate.reasons.joined(separator: " "))
            }
            try await Task.sleep(for: .seconds(20)); waited += 20
        }
    }

    /// Merges every open pull request of the stack, lowest first, past the repository's rules. Each one still has to pass its checks, and the first problem stops the run.
    func mergeAllAsAdmin(_ s: Stack) async { await mergeEveryAsAdmin([s]) }

    /// The same for several stacks: each stack's pull requests lowest first, stacks in the order of their next pull request.
    func mergeEveryAsAdmin(_ list: [Stack]) async {
        await run("Merging") { [method] dir, host in
            var todo = Set(list.flatMap { $0.branches.filter { !$0.isMerged && $0.prState == "OPEN" }.compactMap(\.pr) })
            var merged: [Int] = []
            while !todo.isEmpty {
                let all = await Stacks.load(in: dir, host: host)
                guard let current = all.filter({ $0.bottomOpen?.pr.map(todo.contains) == true }).min(by: { ($0.bottomOpen?.pr ?? .max) < ($1.bottomOpen?.pr ?? .max) }), let n = current.bottomOpen?.pr else { break }
                self.notice = merged.isEmpty ? nil : "Merged \(merged.map { "#\($0)" }.joined(separator: ", ")). Next: #\(n)…"
                self.busy = "Merging #\(n)"
                try await self.waitUntilReady(n, dir: dir, merged: merged)
                do { merged.append(try await self.mergeOne(current, admin: true, method: method, dir: dir, host: host)) }
                catch { throw StackError.message((merged.isEmpty ? "" : "Merged \(merged.map { "#\($0)" }.joined(separator: ", ")), then stopped. ") + error.localizedDescription) }
                todo.remove(n)
            }
            return merged.isEmpty ? "Nothing was left to merge." : "Merged \(merged.map { "#\($0)" }.joined(separator: ", ")) as admin."
        }
    }

    /// One merge of the lowest open pull request, then restack and resubmit what is left. Returns its number.
    private func mergeOne(_ s: Stack, admin: Bool, method: MergeMethod, dir: String, host: StackHost) async throws -> Int {
        guard let bottom = s.branches.first(where: { !$0.isMerged && $0.prState == "OPEN" }), let n = bottom.pr else { throw StackError.message("Submit the stack first. There is no open pull request to merge.") }
        let gate = await PRCenter.shared.gateFor(n, dir: dir)
        guard gate.ready else { throw StackError.message("#\(n) is not ready: " + gate.reasons.joined(separator: " ")) }
        do { _ = try await Stacks.mergeBottom(s, in: dir, host: host, method: method, admin: admin) }
        catch where GitHub.isPolicyBlocked(error) {
            self.policyBlocked.insert(n)
            if admin { throw StackError.message("GitHub refused even as an administrator. Your account may not be allowed to bypass this rule.") }
            throw StackError.message("GitHub's rules for this repository refuse to merge #\(n), although its checks pass. Look at the rules on GitHub (Settings, Rules): a required review, or a rule that restricts who can update \(s.trunk).")
        }
        _ = try await Stacks.sync(in: dir, host: host)
        if let fresh = await Stacks.load(in: dir, host: host).first(where: { st in st.branches.contains { !$0.isMerged } }) { _ = try await Stacks.submit(fresh, in: dir, host: host) }
        if let done = await Stacks.load(in: dir, host: host).first(where: { $0.branches.contains { $0.isMerged } }) { await Stacks.cleanUp(done, in: dir) }
        return n
    }

    func create(_ name: String) async {
        await run("Creating") { dir, _ in
            try await Stacks.create(Git.slugify(name), in: dir)
            return "Created \(Git.slugify(name)) on top of your current branch."
        }
    }

    func abort() async { guard let r = repo else { return }; await Exec.with(env) { await Stacks.abortRestack(in: r.dir) }; conflict = nil; await refresh() }

    /// Always a session of its own, started in the folder where the rebase is stopped. Reusing the branch's earlier session would put the
    /// agent in a different folder, and that session may be stopped.
    func resolveWithAgent() async {
        guard let r = repo else { return }
        guard let c = await Exec.with(env, { await Stacks.pendingConflict(in: r.dir) }) else { await refresh(); return }
        let files = c.files.isEmpty ? "the conflicted files (see `git status`)" : c.files.joined(separator: ", ")
        let prompt = "A restack stopped on a merge conflict in \(files) while rebasing the branch \(c.branch). This folder is in the middle of that rebase. Resolve the conflict markers so both sides' intent is kept, run the tests, `git add` the files and run `git -c core.editor=true rebase --continue`. If more conflicts appear, resolve them the same way. Do not push."
        let level: AccessLevel = [.readOnly, .askFirst].contains(Workspace.shared.policy.defaultLevel) ? .editFiles : Workspace.shared.policy.defaultLevel
        do {
            try await Workspace.shared.create(.init(folder: c.dir, access: level, firstMessage: prompt, environment: r.environment, title: "Resolve conflict: \(c.branch)"))
            AppDelegate.shared.showManager(pane: .sessions)
        } catch { AppModel.shared.fail(error, action: "Start the session that resolves the conflict") }
    }
}

struct StacksView: View {
    let center = StackCenter.shared
    let pr = PRCenter.shared
    @State private var newName = ""
    @State private var confirmBypassEvery = false
    @State private var splitting = false
    @State private var startOpen = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Stacks", subtitle: center.repo?.name ?? "Small pull requests that build on each other") {
                HStack(spacing: 8) {
                    AsyncButton { await center.sync() } label: {
                        if center.busy == "Syncing" { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }.buttonStyle(.soft).disabled(center.busy != nil || center.loading || center.conflict != nil).help("Fetch, update the trunk and restack").accessibilityLabel("Sync")
                    AsyncButton { await center.refresh(manual: true) } label: {
                        if center.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.soft).disabled(center.loading || center.busy != nil).help("Reload the stacks and their pull requests").accessibilityLabel("Refresh")
                }
            }
            if center.repo == nil {
                VStack(spacing: 8) {
                    Text("Choose a repository").font(.system(size: 15, weight: .semibold))
                    if let first = pr.repos().first { AsyncButton("Open \(first.name)") { await center.open(first) }.buttonStyle(Pill(kind: .primary)) }
                    else { Text("Start a session in a project first.").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        banners
                        mergeEverything
                        if center.stacks.isEmpty && !center.loading { Text("No stacks yet. Start one below.").font(.system(size: 13)).foregroundStyle(.secondary) }
                        ForEach(center.stacks.sorted { ($0.bottomOpen?.pr ?? .max) < ($1.bottomOpen?.pr ?? .max) }) { s in StackCard(stack: s) }
                        startSection
                    }.padding(22).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.pane)
        .onAppear { Project.shared.ensureDefault(); if let r = Project.shared.current { Task { await center.open(r) } } }
        .onChange(of: Project.shared.current) { _, r in if let r, r != center.repo { Task { await center.open(r) } } }
        .sheet(isPresented: $splitting) { SplitSheet() }
    }

    /// Stacks whose next pull request GitHub's rules refuse although its checks pass.
    private var blockedStacks: [Stack] {
        center.stacks.filter { s in
            guard let n = s.bottomOpen?.pr else { return false }
            return center.policyBlocked.contains(n) || s.bottomOpen?.mergeState == "BLOCKED"
        }.sorted { ($0.bottomOpen?.pr ?? .max) < ($1.bottomOpen?.pr ?? .max) }
    }

    /// One button for all of them, for the common case of many one-pull-request stacks that each wait on the same rule.
    @ViewBuilder private var mergeEverything: some View {
        let blocked = blockedStacks
        let total = blocked.reduce(0) { $0 + $1.branches.filter { !$0.isMerged && $0.prState == "OPEN" }.count }
        if Prefs.shared.adminMergeAll, blocked.count > 1, center.busy == nil {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub's rules block \(blocked.count) stacks").font(.system(size: 12.5, weight: .semibold))
                    Text("Merge all \(total) pull requests as admin, one after another.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Merge all \(total) as admin…") { confirmBypassEvery = true }.buttonStyle(Pill(kind: .plain))
                    .confirmationDialog("Bypass the repository's rules to merge \(total) pull requests?", isPresented: $confirmBypassEvery, titleVisibility: .visible) {
                        Button("Merge all \(total) as admin", role: .destructive) { Task { await center.mergeEveryAsAdmin(blocked) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Merges every open pull request in these stacks one after another, lowest number first, overriding GitHub's rules on each. Every one still has to pass its checks, and it stops at the first problem. The merges are recorded as bypasses. You can turn this button off in Settings.")
                    }
            }.padding(12).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private var banners: some View {
        if let b = center.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(b)…").font(.system(size: 12.5)) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9)) }
        if let n = center.notice { Label(n, systemImage: "checkmark.circle").font(.system(size: 12.5)).foregroundStyle(Theme.ok).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)) }
        if let e = center.error { Label { ErrorLine(text: e) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 9)) }
        if let c = center.conflict {
            VStack(alignment: .leading, spacing: 8) {
                Label("Restacking \(c.branch) hit a conflict", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text(c.files.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    AsyncButton("Resolve with Claude") { await center.resolveWithAgent() }.buttonStyle(Pill(kind: .primary))
                    AsyncButton("Abort restack") { await center.abort() }.buttonStyle(Pill(kind: .plain))
                }
            }.padding(12).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warn))
        }
    }

    /// Ways to make a stack. Folded away once there is a stack to work on; open by itself when there are none.
    private var startSection: some View {
        let open = startOpen || center.stacks.isEmpty
        return VStack(spacing: 0) {
            Button { if !center.stacks.isEmpty { startOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).opacity(center.stacks.isEmpty ? 0.3 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Create a stack").font(.system(size: 13, weight: .semibold))
                        Text("Start one by hand, split a big branch, or build one from a spec.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.soft)
            if open {
                Divider()
                SettingRow("Stack a new branch", "Creates a branch on top of the one checked out in this repository.") {
                    HStack(spacing: 6) {
                        TextField("branch name", text: $newName).textFieldStyle(CPField()).frame(width: 170)
                        AsyncButton("Create") { let n = newName; newName = ""; await center.create(n) }.buttonStyle(Pill(kind: .plain)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                SettingRow("Split a big change into a stack", "An agent proposes logical pieces of a large branch. You edit the plan, then each piece gets its own branch.") {
                    Button("Propose a split…") { splitting = true }.buttonStyle(Pill(kind: .primary))
                }
                SettingRow("From a spec", "Tasks that depend on each other are built as a stack automatically.", separator: false) {
                    Button("Open specs") { Nav.shared.pane = .specs }.buttonStyle(Pill(kind: .plain))
                }
            }
        }
        .padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .animation(.easeInOut(duration: 0.2), value: open)
    }
}

struct StackCard: View {
    let stack: Stack
    let center = StackCenter.shared
    @State private var confirmBypass = false
    @State private var confirmBypassAll = false

    var body: some View {
        @Bindable var c = center
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(stack.branches.first(where: { !$0.isMerged })?.title ?? stack.branches.last?.name ?? "Stack").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Badge(text: "\(stack.branches.filter { !$0.isMerged }.count) open", kind: .accent)
                if stack.needsRestack { Badge(text: "Needs restack", kind: .warn) }
                Spacer()
                Button { Task { await center.restack(stack) } } label: { BusyLabel(title: "Restack", busyTitle: "Restacking…", busy: center.busy == "Restacking") }.buttonStyle(Pill(kind: .plain)).disabled(!stack.needsRestack || stack.nextStep == .sync || center.conflict != nil || center.busy != nil)
                Button { Task { await center.submit(stack) } } label: { BusyLabel(title: "Submit", busyTitle: "Submitting…", busy: center.busy == "Submitting") }.buttonStyle(Pill(kind: .plain))
                    .disabled(center.conflict != nil || stack.nextStep == .sync || stack.needsRestack || stack.unsubmitted.isEmpty || center.busy != nil)
                Button { Task { await center.mergeBottom(stack) } } label: { BusyLabel(title: "Merge from the bottom", busyTitle: "Merging…", busy: center.busy == "Merging") }.buttonStyle(Pill(kind: .primary))
                    .disabled(center.conflict != nil || stack.nextStep != .merge || checkState == .failed || center.busy != nil)
            }
            nextStepBar
            Text("⎇ \(stack.trunk)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            VStack(spacing: 6) { ForEach(stack.branches) { b in StackNode(branch: b, stack: stack) } }
                .padding(.leading, 14).overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2).padding(.vertical, 10) }
            HStack {
                Text("Merge style").font(.system(size: 12)).foregroundStyle(.secondary)
                Segmented(options: [(MergeMethod.squash, "Squash"), (.merge, "Merge"), (.rebase, "Rebase")], selection: $c.method)
            }
        }.card(padding: 14)
    }
}

extension StackCard {
    private struct Step { let icon: String, tint: Color, title: String, detail: String }
    private enum CheckState { case unknown, passing, pending, failed }

    private var bottomChecks: [PullRequest.Check] { stack.bottomOpen?.pr.flatMap { center.checks[$0] } ?? [] }
    private var checkState: CheckState {
        let c = bottomChecks
        if c.isEmpty { return .unknown }
        if c.contains(where: \.failed) { return .failed }
        return c.allSatisfy(\.passed) ? .passing : .pending
    }

    private var step: Step {
        let n = stack.bottomOpen?.pr ?? 0
        if let c = center.conflict {
            return Step(icon: "exclamationmark.triangle.fill", tint: Theme.warn, title: "Resolve the conflict in \(c.branch)",
                        detail: "A restack stopped half-way. Resolve it with Claude, or abort the restack, before anything else.")
        }
        switch stack.nextStep {
        case .sync: return Step(icon: "arrow.down.circle", tint: Theme.warn, title: "\(stack.trunk) has new commits",
                                detail: "\(stack.trunkBehind) new on GitHub, for example a fix you merged. Sync pulls them in and restacks, so the branches are tested with them.")
        case .restack: return Step(icon: "arrow.triangle.2.circlepath", tint: Theme.warn, title: "Restack first",
                                   detail: "A branch is behind its parent, or a lower pull request was merged. Submit and merge wait until then.")
        case .submit: return Step(icon: "arrow.up.circle", tint: Theme.accent, title: "Submit to publish your changes",
                                  detail: names(stack.unsubmitted.map(\.name)) + " no open pull request, or has commits GitHub hasn't seen.")
        case .merge:
            switch checkState {
            case .failed:
                let failed = bottomChecks.filter(\.failed).map(\.name).joined(separator: ", ")
                return Step(icon: "xmark.octagon", tint: Theme.danger, title: "#\(n) failed its checks",
                            detail: "\(failed) failed. Fix it on the branch and Submit. If it looks unrelated, such as a flaky test, merge a fix into \(stack.trunk) first, then Sync.")
            case .pending: return Step(icon: "clock", tint: Theme.accent, title: "Waiting for checks on #\(n)", detail: "It can merge once they pass. Refresh to see the latest.")
            default:
                let state = stack.bottomOpen?.mergeState
                if center.policyBlocked.contains(n) || state == "BLOCKED" {
                    return Step(icon: "lock.fill", tint: Theme.warn, title: "GitHub's rules block #\(n)",
                                detail: "Its checks pass, but the repository's rules still refuse the merge, for example a required review or a rule that restricts who can update \(stack.trunk). Auto-merge waits until GitHub allows it.")
                }
                switch state {
                case "DIRTY": return Step(icon: "exclamationmark.triangle.fill", tint: Theme.warn, title: "#\(n) has merge conflicts", detail: "Resolve them on the branch, then Submit.")
                case "BEHIND": return Step(icon: "arrow.down.circle", tint: Theme.warn, title: "#\(n) is behind \(stack.trunk)", detail: "Sync pulls the new commits in and restacks.")
                case "DRAFT": return Step(icon: "pencil.circle", tint: Theme.accent, title: "#\(n) is still a draft", detail: "Mark it ready for review on GitHub. Nothing merges until then.")
                case "UNKNOWN", nil: return Step(icon: "clock", tint: Theme.accent, title: "Waiting for GitHub on #\(n)", detail: "GitHub has not said yet whether it can merge. Refresh in a moment.")
                default: return Step(icon: "checkmark.circle", tint: Theme.ok, title: "#\(n) is ready to merge",
                                     detail: center.isArmed(center.repo ?? .init(dir: "")) ? "GitHub allows it. Auto-merge merges it within a minute." : "GitHub allows it. Press Merge from the bottom.")
                }
            }
        case nil: return Step(icon: "tray", tint: .secondary, title: "Nothing to do", detail: "No open pull requests in this stack.")
        }
    }

    private func names(_ n: [String]) -> String {
        n.count <= 2 ? n.joined(separator: " and ") + (n.count == 1 ? " has" : " have") : "\(n[0]), \(n[1]) and \(n.count - 2) more have"
    }

    /// One tidy row: what to do next on the left, its action if it has one, and the auto-merge switch on the right.
    @ViewBuilder var nextStepBar: some View {
        let st = step
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: st.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(st.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.title).font(.system(size: 12.5, weight: .semibold))
                    Text(st.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                if stack.nextStep == .merge, let n = stack.bottomOpen?.pr, center.policyBlocked.contains(n) || stack.bottomOpen?.mergeState == "BLOCKED", checkState != .failed, checkState != .pending {
                    if Prefs.shared.adminMergeAll, stack.branches.filter({ !$0.isMerged && $0.prState == "OPEN" }).count > 1 {
                        Button("Merge all as admin…") { confirmBypassAll = true }.buttonStyle(Pill(kind: .plain)).disabled(center.busy != nil)
                            .confirmationDialog("Bypass the repository's rules to merge every open pull request?", isPresented: $confirmBypassAll, titleVisibility: .visible) {
                                Button("Merge all \(stack.branches.filter { !$0.isMerged && $0.prState == "OPEN" }.count) as admin", role: .destructive) { Task { await center.mergeAllAsAdmin(stack) } }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Merges the open pull requests of this stack one after another, lowest first, overriding GitHub's rules for \(stack.trunk) on each. Every one still has to pass its checks, and it stops at the first problem. The merges are recorded as bypasses. You can turn this button off in Settings.")
                            }
                    }
                    Button("Merge as admin…") { confirmBypass = true }.buttonStyle(Pill(kind: .plain)).disabled(center.busy != nil)
                        .confirmationDialog("Bypass the repository's rules to merge #\(n)?", isPresented: $confirmBypass, titleVisibility: .visible) {
                            Button("Merge #\(n) as admin", role: .destructive) { Task { await center.mergeBottom(stack, admin: true) } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("GitHub's rules for \(stack.trunk) refuse this merge. As an administrator you can override them for this one pull request. The rules stay in place for everyone else, and the merge is recorded as a bypass.")
                        }
                }
                if stack.nextStep == .sync {
                    AsyncButton("Sync now") { await center.sync() }.buttonStyle(Pill(kind: .primary)).disabled(center.busy != nil)
                } else if stack.nextStep == .merge, checkState == .failed, let link = bottomChecks.first(where: \.failed)?.link, let url = URL(string: link) {
                    Button("View run") { NSWorkspace.shared.open(url) }.buttonStyle(Pill(kind: .plain))
                }
                Spacer(minLength: 12)
                if let r = center.repo {
                    let on = center.isArmed(r)
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Auto-merge").font(.system(size: 12, weight: .medium))
                            Toggle("", isOn: Binding(get: { on }, set: { center.arm(repo: r, on: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                        }
                        Text(on ? "Merges bottom first when rules pass" : "Off: you merge by hand").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.help("Merge the stack automatically, bottom first, whenever every rule passes")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(st.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(st.tint.opacity(0.25)))
        .animation(.easeInOut(duration: 0.2), value: stack.nextStep)
    }
}

struct StackNode: View {
    let branch: StackBranch
    let stack: Stack
    let center = StackCenter.shared
    /// 1, 2, 3 … down the open branches, the order "Merge from the bottom" takes them in.
    private var order: Int? { branch.isMerged ? nil : stack.branches.filter { !$0.isMerged }.firstIndex(of: branch).map { $0 + 1 } }
    private var isNext: Bool { stack.bottomOpen?.name == branch.name }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(branch.isMerged ? Theme.ok : branch.needsRestack ? Theme.warn : Theme.accent).frame(width: 10, height: 10).offset(x: -19)
            if let n = order { Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(isNext ? Theme.accent : .secondary).frame(width: 18).help("Merge order: the stack merges from 1 upwards") }
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text([branch.pr.map { "#\($0)" }, branch.title, "\(branch.commits) commit\(branch.commits == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, CGFloat(branch.depth) * 14 - 8)
            Spacer()
            if branch.isMerged { Badge(text: "Merged", kind: .ok) }
            else if isNext, !branch.needsRestack, branch.prState == "OPEN" { Badge(text: "Merges next", kind: .accent) }
            else if branch.needsRestack { Badge(text: "Behind", kind: .warn) }
            else if branch.prState == "OPEN" { Badge(text: "Open", kind: .accent) }
            else { Badge(text: "No PR yet") }
            if let n = branch.pr, !branch.isMerged {
                AsyncButton("Pull request") { await PRCenter.shared.open(repo: center.repo?.dir ?? "", environment: center.repo?.environment); await PRCenter.shared.select(n); Nav.shared.pane = .pulls }.buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            if !branch.isMerged {
                AsyncButton("Session") { _ = try? await Workspace.shared.startSession(onBranch: branch.name, repo: center.repo?.dir ?? "", environment: center.repo?.environment); Nav.shared.pane = .sessions }.buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }
}

/// An agent proposes how to cut a big branch into reviewable pieces; you edit the plan; each piece becomes a branch.
struct SplitSheet: View {
    let center = StackCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [String] = []
    @State private var source = ""
    @State private var pieces: [Stacks.Piece] = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split a big change into a stack").font(.system(size: 16, weight: .semibold))
            Text("Pick the branch that holds the whole change. Pieces split by file: the top of the stack ends up identical to it.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Dropdown(options: branches.map { ($0, $0) }, selection: $source, placeholder: "Choose a branch").frame(width: 260)
                AsyncButton { await propose() } label: { if working { ProgressView().controlSize(.small) } else { Label("Propose a split", systemImage: "sparkles") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(source.isEmpty || working)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(pieces.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(i + 1)").font(.system(size: 11)).frame(width: 20, height: 20).background(Theme.fill, in: Circle())
                                TextField("branch", text: $pieces[i].branch).textFieldStyle(CPField()).font(.system(size: 12, design: .monospaced))
                                Button { pieces.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.soft).foregroundStyle(.secondary)
                            }
                            TextField("commit message", text: $pieces[i].message).textFieldStyle(CPField())
                            Text(pieces[i].files.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
                    }
                }
            }.frame(height: 260)
            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Create stack") { let p = pieces, s = source; dismiss(); Task { await center.run("Splitting") { dir, _ in try await Stacks.split(source: s, pieces: p, in: dir); return "Created a stack of \(p.count) branches." } } }
                    .buttonStyle(Pill(kind: .primary)).disabled(pieces.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560).task { await load() }
    }

    private func load() async {
        guard let r = center.repo else { return }
        let trunk = await Exec.with(center.env) { await Stacks.trunk(in: r.dir) }
        let out = (try? await Exec.with(center.env) { try await Shell.check("git", ["for-each-ref", "--format=%(refname:short)", "--no-contains", trunk, "refs/heads"], cwd: URL(fileURLWithPath: r.dir)) }) ?? ""
        let ahead = (try? await Exec.with(center.env) { try await Shell.check("git", ["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: URL(fileURLWithPath: r.dir)) }) ?? out
        branches = ahead.split(separator: "\n").map(String.init).filter { $0 != trunk }
        source = (try? await Exec.with(center.env) { try await Shell.check("git", ["branch", "--show-current"], cwd: URL(fileURLWithPath: r.dir)) })?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty(in: branches) ?? branches.first ?? ""
    }

    private func propose() async {
        guard let r = center.repo else { return }
        working = true; error = nil; defer { working = false }
        let (files, stat, diff) = await Exec.with(center.env) { () -> ([String], String, String) in
            let f = await Stacks.changedFiles(source: source, in: r.dir)
            let t = await Stacks.trunk(in: r.dir)
            let stat = (try? await Shell.check("git", ["diff", "--stat", "\(t)...\(source)"], cwd: URL(fileURLWithPath: r.dir))) ?? ""
            let d = (try? await Shell.check("git", ["diff", "-U0", "\(t)...\(source)"], cwd: URL(fileURLWithPath: r.dir))) ?? ""
            return (f, stat, String(d.prefix(24000)))
        }
        guard !files.isEmpty else { error = "This branch has no changes compared with the trunk."; return }
        let prompt = "Split this change into 2 to 6 logical pieces that can each be reviewed on their own and build on each other in order (for example: types and helpers first, then logic, then UI, then docs and tests). Every changed file must appear in exactly one piece. Reply with ONLY a JSON array like [{\"branch\":\"short-kebab-name\",\"message\":\"commit message\",\"files\":[\"path\"]}].\n\nFiles:\n\(files.joined(separator: "\n"))\n\nDiff summary:\n\(stat)\n\nDiff:\n\(diff)"
        let out = await ClaudeOneShot.run(prompt, in: env == nil ? r.dir : NSHomeDirectory(), timeout: 150)
        let plan = out.map { Stacks.parsePlan($0, changed: files) } ?? []
        if plan.isEmpty { error = "Claude could not propose a split. Try again, or create the branches by hand."; pieces = [Stacks.Piece(branch: "part-1", message: "", files: files)] } else { pieces = plan }
    }

    private var env: EnvironmentConfig? { center.env }
}

private extension String {
    func nonEmpty(in list: [String]) -> String? { list.contains(self) ? self : nil }
}
