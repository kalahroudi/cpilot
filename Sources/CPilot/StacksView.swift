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
    var loading = false
    var busy: String?
    var error: String?
    var conflict: (branch: String, files: [String])?
    var notice: String?
    var method: MergeMethod = .squash
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
                let gate = await PRCenter.shared.gateFor(n, dir: dir)
                guard gate.ready else { return true }
                do {
                    _ = try await Stacks.mergeBottom(stack, in: dir, host: host, method: method)
                    _ = try await Stacks.sync(in: dir, host: host)
                    if let fresh = await Stacks.load(in: dir, host: host).first(where: { st in st.branches.contains { !$0.isMerged } }) { _ = try await Stacks.submit(fresh, in: dir, host: host) }
                    AppModel.shared.notify("Merged #\(n)", body: stack.branches.last?.title ?? "")
                } catch { AppLog.error(error, context: "auto-merge stack") }
                return true
            }
            if !open { armed[key] = nil; UserDefaults.standard.set(armed, forKey: "armedStacks") }
        }
        if armed.isEmpty { watcher?.cancel(); watcher = nil }
    }

    func open(_ r: PRCenter.Repo) async { repo = r; Project.shared.current = r; conflict = nil; error = nil; notice = nil; await refresh() }

    func refresh() async {
        guard let r = repo else { return }
        loading = true; defer { loading = false }
        stacks = await Exec.with(env) { await Stacks.load(in: r.dir, host: LiveStackHost(dir: r.dir)) }
    }

    /// Runs one stack operation with a visible label, on the right machine, and turns failures into plain messages.
    func run(_ label: String, _ body: @escaping (String, StackHost) async throws -> String?) async {
        guard let r = repo, busy == nil else { return }
        busy = label; error = nil; notice = nil; conflict = nil
        defer { busy = nil }
        do {
            let msg = try await Exec.with(env) { try await body(r.dir, LiveStackHost(dir: r.dir)) }
            notice = msg
        } catch let e as StackError {
            if case .conflict(let b, let f) = e { conflict = (b, f) } else { error = e.localizedDescription }
        } catch { self.error = UserError.message(for: error, action: label) }
        await refresh()
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
    func mergeBottom(_ s: Stack) async {
        await run("Merging") { [method] dir, host in
            guard let bottom = s.branches.first(where: { !$0.isMerged && $0.prState == "OPEN" }), let n = bottom.pr else { throw StackError.message("Submit the stack first. There is no open pull request to merge.") }
            let gate = await PRCenter.shared.gateFor(n, dir: dir)
            guard gate.ready else { throw StackError.message("#\(n) is not ready: " + gate.reasons.joined(separator: " ")) }
            _ = try await Stacks.mergeBottom(s, in: dir, host: host, method: method)
            _ = try await Stacks.sync(in: dir, host: host)
            if let fresh = await Stacks.load(in: dir, host: host).first(where: { st in st.branches.contains { !$0.isMerged } }) { _ = try await Stacks.submit(fresh, in: dir, host: host) }
            if let done = await Stacks.load(in: dir, host: host).first(where: { $0.branches.contains { $0.isMerged } }) { await Stacks.cleanUp(done, in: dir) }
            return "Merged #\(n). The next pull request is waiting for its checks."
        }
    }

    func create(_ name: String) async {
        await run("Creating") { dir, _ in
            try await Stacks.create(Git.slugify(name), in: dir)
            return "Created \(Git.slugify(name)) on top of your current branch."
        }
    }

    func abort() async { guard let r = repo else { return }; await Exec.with(env) { await Stacks.abortRestack(in: r.dir) }; conflict = nil; await refresh() }

    func resolveWithAgent() async {
        guard let r = repo, let c = conflict else { return }
        let prompt = "A restack stopped on a merge conflict in \(c.files.joined(separator: ", ")) while rebasing the branch \(c.branch). Resolve the conflict markers so both sides' intent is kept, run the tests, stage the files and run `git rebase --continue`. Do not push."
        _ = try? await Workspace.shared.startSession(onBranch: c.branch, repo: r.dir, environment: r.environment, prompt: prompt)
        AppDelegate.shared.showManager(pane: .sessions)
    }
}

struct StacksView: View {
    let center = StackCenter.shared
    let pr = PRCenter.shared
    @State private var newName = ""
    @State private var splitting = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Stacks", subtitle: center.repo?.name ?? "Small pull requests that build on each other") {
                HStack(spacing: 8) {
                    RepoMenu()
                    Button { Task { await center.sync() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.plain).help("Fetch, update the trunk and restack").accessibilityLabel("Sync")
                    Button { Task { await center.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
                }
            }
            if center.repo == nil {
                VStack(spacing: 8) {
                    Text("Choose a repository").font(.system(size: 15, weight: .semibold))
                    if let first = pr.repos().first { Button("Open \(first.name)") { Task { await center.open(first) } }.buttonStyle(Pill(kind: .primary)) }
                    else { Text("Start a session in a project first.").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        banners
                        if center.stacks.isEmpty && !center.loading { Text("No stacks yet. Start one below.").font(.system(size: 13)).foregroundStyle(.secondary) }
                        ForEach(center.stacks) { s in StackCard(stack: s) }
                        startSection
                    }.padding(22).frame(maxWidth: 860, alignment: .leading)
                }
            }
        }
        .background(Theme.pane)
        .onAppear { Project.shared.ensureDefault(); if let r = Project.shared.current, r != center.repo { Task { await center.open(r) } } }
        .onChange(of: Project.shared.current) { _, r in if let r, r != center.repo { Task { await center.open(r) } } }
        .sheet(isPresented: $splitting) { SplitSheet() }
    }

    @ViewBuilder private var banners: some View {
        if let b = center.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(b)…").font(.system(size: 12.5)) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9)) }
        if let n = center.notice { Label(n, systemImage: "checkmark.circle").font(.system(size: 12.5)).foregroundStyle(Theme.ok).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)) }
        if let e = center.error { Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.danger).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 9)) }
        if let c = center.conflict {
            VStack(alignment: .leading, spacing: 8) {
                Label("Restacking \(c.branch) hit a conflict", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text(c.files.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    Button("Resolve with Claude") { Task { await center.resolveWithAgent() } }.buttonStyle(Pill(kind: .primary))
                    Button("Abort restack") { Task { await center.abort() } }.buttonStyle(Pill(kind: .plain))
                }
            }.padding(12).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warn))
        }
    }

    private var startSection: some View {
        VStack(spacing: 0) {
            SettingRow("Stack a new branch", "Creates a branch on top of the one checked out in this repository.") {
                HStack(spacing: 6) {
                    TextField("branch name", text: $newName).textFieldStyle(CPField()).frame(width: 170)
                    Button("Create") { let n = newName; newName = ""; Task { await center.create(n) } }.buttonStyle(Pill(kind: .plain)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            SettingRow("Split a big change into a stack", "An agent proposes logical pieces of a large branch. You edit the plan, then each piece gets its own branch.") {
                Button("Propose a split…") { splitting = true }.buttonStyle(Pill(kind: .primary))
            }
            SettingRow("From a spec", "Tasks that depend on each other are built as a stack automatically.") {
                Button("Open specs") { Nav.shared.pane = .specs }.buttonStyle(Pill(kind: .plain))
            }
        }.padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

struct StackCard: View {
    let stack: Stack
    let center = StackCenter.shared

    var body: some View {
        @Bindable var c = center
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(stack.branches.last(where: { !$0.isMerged })?.title ?? stack.branches.last?.name ?? "Stack").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Badge(text: "\(stack.branches.filter { !$0.isMerged }.count) open", kind: .accent)
                if stack.needsRestack { Badge(text: "Needs restack", kind: .warn) }
                Spacer()
                Button("Restack") { Task { await center.restack(stack) } }.buttonStyle(Pill(kind: .plain)).disabled(!stack.needsRestack || center.busy != nil)
                Button("Submit") { Task { await center.submit(stack) } }.buttonStyle(Pill(kind: .plain)).disabled(center.busy != nil)
                Button("Merge from the bottom") { Task { await center.mergeBottom(stack) } }.buttonStyle(Pill(kind: .primary)).disabled(center.busy != nil)
                if let r = center.repo { Toggle("", isOn: Binding(get: { center.isArmed(r) }, set: { center.arm(repo: r, on: $0) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent).help("Merge the stack automatically, bottom first, whenever every rule passes") }
            }
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

struct StackNode: View {
    let branch: StackBranch
    let stack: Stack
    let center = StackCenter.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(branch.isMerged ? Theme.ok : branch.needsRestack ? Theme.warn : Theme.accent).frame(width: 10, height: 10).offset(x: -19)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text([branch.pr.map { "#\($0)" }, branch.title, "\(branch.commits) commit\(branch.commits == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, CGFloat(branch.depth) * 14 - 8)
            Spacer()
            if branch.isMerged { Badge(text: "Merged", kind: .ok) }
            else if branch.needsRestack { Badge(text: "Behind", kind: .warn) }
            else if branch.prState == "OPEN" { Badge(text: "Open", kind: .accent) }
            else { Badge(text: "No PR yet") }
            if let n = branch.pr, !branch.isMerged {
                Button("Pull request") { Task { await PRCenter.shared.open(repo: center.repo?.dir ?? "", environment: center.repo?.environment); await PRCenter.shared.select(n); Nav.shared.pane = .pulls } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            if !branch.isMerged {
                Button("Session") { Task { _ = try? await Workspace.shared.startSession(onBranch: branch.name, repo: center.repo?.dir ?? "", environment: center.repo?.environment); Nav.shared.pane = .sessions } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
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
                Button { Task { await propose() } } label: { if working { ProgressView().controlSize(.small) } else { Label("Propose a split", systemImage: "sparkles") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(source.isEmpty || working)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(pieces.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(i + 1)").font(.system(size: 11)).frame(width: 20, height: 20).background(Theme.fill, in: Circle())
                                TextField("branch", text: $pieces[i].branch).textFieldStyle(CPField()).font(.system(size: 12, design: .monospaced))
                                Button { pieces.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            TextField("commit message", text: $pieces[i].message).textFieldStyle(CPField())
                            Text(pieces[i].files.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
                    }
                }
            }.frame(height: 260)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
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
