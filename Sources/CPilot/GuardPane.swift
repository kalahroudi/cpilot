// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// One worktree whose staged change is waiting for a person's approval before the repository's guard lets it be committed.
struct GuardItem: Identifiable, Equatable {
    var id: String { session }
    var session: String
    var title: String
    var taskId: String?
    var repo: String
    var branch: String
    var worktree: String
    var staged: [String]
    var diff: [DiffFile]
    var runner: ProjectScripts.Found
    var script: String
}

/// Every worktree across all sessions and repositories that is waiting for `guard:approve` (or the repository's own approval script), in one list.
@MainActor @Observable
final class GuardCenter {
    static let shared = GuardCenter()
    private(set) var items: [GuardItem] = []
    private(set) var scanning = false
    /// What running each item's approval and commit printed, and where each one stands.
    var output: [String: String] = [:]
    var stage: [String: String] = [:]
    var messages: [String: String] = [:]
    /// An item can be approved in bulk only after its diff was opened: the guard exists so a person looks first.
    var viewed: Set<String> = []
    var working: Set<String> = []

    func scan() async {
        guard !scanning else { return }
        scanning = true; defer { scanning = false }
        let ws = Workspace.shared
        var found: [GuardItem] = []
        for m in ws.sessions where !m.archived && m.environment == nil && m.chief != true {
            guard let wt = m.worktree, FileManager.default.fileExists(atPath: wt) else { continue }
            let url = URL(fileURLWithPath: wt)
            let status = GitStatusSummary.parse((try? await Shell.check("git", ["status", "--porcelain=v1", "-z"], cwd: url, timeout: 20)) ?? "")
            guard !status.staged.isEmpty else { continue }
            let scripts = Self.scripts(in: wt)
            guard let pick = GuardApproval.approveScript(scripts) else { continue }
            let diff = DiffParser.parse((try? await Shell.check("git", ["diff", "--cached", "--no-color"], cwd: url, timeout: 30)) ?? "")
            var task: (id: String, title: String)?
            for d in SpecHub.shared.allDocs() { if let t = d.tasks.first(where: { $0.branch != nil && $0.branch == m.branch }) { task = (t.id, t.title) } }
            found.append(GuardItem(session: m.id, title: task.map { "\($0.id) \($0.title)" } ?? m.title, taskId: task?.id, repo: m.cwd, branch: m.branch ?? "", worktree: wt,
                                   staged: status.staged, diff: diff, runner: pick.found, script: pick.script))
            if messages[m.id] == nil { messages[m.id] = GuardApproval.suggestedMessage(taskId: task?.id, title: task?.title ?? m.title) }
        }
        let ids = Set(found.map(\.id))
        for k in stage.keys where !ids.contains(k) && stage[k] != "committed" { stage[k] = nil }
        items = found.sorted { $0.title < $1.title }
    }

    nonisolated static func scripts(in dir: String) -> [ProjectScripts.Found] {
        func read(_ f: String) -> String? { try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) }
        let lock = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).intersection(["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lockb", "bun.lock"])
        return [read("package.json").flatMap { ProjectScripts.node(packageJSON: $0, lockfiles: lock) }, read("Makefile").flatMap(ProjectScripts.make), read("justfile").flatMap(ProjectScripts.just)].compactMap { $0 }
    }

    private func log(_ item: GuardItem, _ line: String) { output[item.id, default: ""] += line + "\n" }

    /// Runs the repository's own approval, stages the lock file it wrote and commits with the message shown. Stops at the first step that fails and says which.
    func approveAndCommit(_ item: GuardItem) async {
        guard !working.contains(item.id) else { return }
        working.insert(item.id); defer { working.remove(item.id) }
        output[item.id] = ""; stage[item.id] = "approving"
        let url = URL(fileURLWithPath: item.worktree)
        let message = (messages[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { stage[item.id] = "failed"; log(item, "Write a commit message first."); return }
        do {
            let inv = GuardApproval.invocation(item.runner, item.script)
            let a = try await Shell.run(inv.tool, inv.args, cwd: url, timeout: 180)
            log(item, "$ \(inv.tool) \(inv.args.joined(separator: " "))\n" + (a.stdout + a.stderr).suffix(2000))
            guard a.ok else { stage[item.id] = "failed"; log(item, "The approval step failed, so nothing was committed."); return }
            let status = GitStatusSummary.parse((try? await Shell.check("git", ["status", "--porcelain=v1", "-z"], cwd: url, timeout: 20)) ?? "")
            let locks = GuardApproval.lockFilesToStage(status)
            if !locks.isEmpty { _ = try await Shell.check("git", ["add", "--"] + locks, cwd: url, timeout: 30); log(item, "Staged " + locks.joined(separator: ", ")) }
            stage[item.id] = "committing"
            let c = try await Shell.run("git", ["commit", "-m", message], cwd: url, timeout: 120)
            log(item, "$ git commit\n" + (c.stdout + c.stderr).suffix(2000))
            guard c.ok else { stage[item.id] = "failed"; log(item, "The commit was refused. Look at the output above; the approval has been recorded."); return }
            stage[item.id] = "committed"
            Workspace.shared.audit.record(AuditEntry(session: item.session, tool: "guard", summary: "\(item.title): approved and committed by the user (\(item.script))", outcome: "allowed by user"))
            if let c = Workspace.shared.controller(item.session) {
                c.addNotice("A person reviewed the staged changes, ran \(item.script) and committed them as \"\(message)\". Carry on from there.")
            }
        } catch { stage[item.id] = "failed"; log(item, error.localizedDescription) }
    }

    func approveViewed() async { for i in items where viewed.contains(i.id) && stage[i.id] != "committed" { await approveAndCommit(i) } }
}

struct GuardPane: View {
    let center = GuardCenter.shared
    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Approvals", subtitle: subtitle) {
                HStack {
                    let ready = center.items.filter { center.viewed.contains($0.id) && center.stage[$0.id] != "committed" }.count
                    if ready > 1 { AsyncButton("Approve \(ready) reviewed") { await center.approveViewed() }.buttonStyle(Pill(kind: .primary)) }
                    AsyncButton("Refresh") { await center.scan() }.buttonStyle(Pill(kind: .plain))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if center.items.isEmpty {
                        Text(center.scanning ? "Looking at every worktree…" : "Nothing is waiting. A task whose commit the repository's guard refuses shows up here with its staged changes.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    ForEach(center.items) { item in card(item) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.task { await center.scan(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(20)); await center.scan() } }
    }

    private var subtitle: String {
        let n = center.items.filter { center.stage[$0.id] != "committed" }.count
        return n == 0 ? "Changes the repository's guard holds until you approve them" : "\(n) waiting across \(Set(center.items.map(\.repo)).count) repositor\(Set(center.items.map(\.repo)).count == 1 ? "y" : "ies"). Open each diff, then approve."
    }

    @ViewBuilder private func card(_ item: GuardItem) -> some View {
        let isOpen = open.contains(item.id), stage = center.stage[item.id], done = stage == "committed", busy = center.working.contains(item.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Badge(text: URL(fileURLWithPath: item.repo).lastPathComponent)
                Badge(text: item.branch)
                Spacer()
                if done { Badge(text: "Committed", kind: .ok) } else if stage == "failed" { Badge(text: "Failed", kind: .danger) } else if center.viewed.contains(item.id) { Badge(text: "Reviewed", kind: .accent) }
            }
            Text("\(item.staged.count) staged: " + item.staged.prefix(6).joined(separator: ", ") + (item.staged.count > 6 ? " and \(item.staged.count - 6) more" : "")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
            if !done {
                Button { if isOpen { open.remove(item.id) } else { open.insert(item.id); center.viewed.insert(item.id) } } label: {
                    Label(isOpen ? "Hide the changes" : "Review the changes", systemImage: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 12))
                }.buttonStyle(.soft).foregroundStyle(Theme.accent)
                if isOpen { VStack(spacing: 6) { ForEach(item.diff) { f in DiffFileView(file: f, collapsed: false, toggle: {}) } } }
                HStack(spacing: 8) {
                    TextField("Commit message", text: Binding(get: { center.messages[item.id] ?? "" }, set: { center.messages[item.id] = $0 })).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    AsyncButton(busy ? "Working…" : "Approve and commit") { await center.approveAndCommit(item) }.buttonStyle(Pill(kind: .primary)).disabled(busy || !center.viewed.contains(item.id))
                }
                if !center.viewed.contains(item.id) { Text("Review the changes first: the guard exists so a person looks at them before they are committed.").font(.system(size: 11)).foregroundStyle(.tertiary) }
                else { Text("Runs `\(item.runner.runner) \(item.script)` in this worktree, stages the lock file it writes, commits, and tells the session to carry on.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            if let out = center.output[item.id], !out.isEmpty {
                Text(out).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.terminal).foregroundStyle(.white.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }.card(padding: 12)
    }
}
