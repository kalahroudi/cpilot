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
            }.buttonStyle(.plain)
            if !collapsed {
                Divider()
                if file.isBinary { Text("Binary file").font(.system(size: 12)).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    ScrollView(.horizontal) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(file.lines.prefix(limit)) { l in line(l) }
                            if file.lines.count > limit {
                                Button("Show \(min(300, file.lines.count - limit)) more lines") { limit += 300 }.buttonStyle(.plain).foregroundStyle(Theme.accent)
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
    var onCreated: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prBody = ""
    @State private var base = "main"
    @State private var branch = ""
    @State private var draft = false
    @State private var busy = false
    @State private var drafting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.system(size: 17, weight: .semibold))
            Text("\(branch) → \(base)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            TextField("Title", text: $title).textFieldStyle(CPField())
            TextEditor(text: $prBody).font(.system(size: 12.5)).frame(height: 140).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack {
                Toggle("Draft", isOn: $draft)
                Spacer()
                Button { Task { await writeWithClaude() } } label: {
                    if drafting { ProgressView().controlSize(.small) } else { Label("Write with Claude", systemImage: "sparkles") }
                }.buttonStyle(Pill(kind: .plain)).disabled(drafting || busy)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { Task { await create() } } label: { if busy { ProgressView().controlSize(.small) } else { Text("Create") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(title.isEmpty || busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .task {
            await Exec.with(env) {
                branch = await Git.info(dir)?.branch ?? ""
                base = await Git.defaultBranch(dir)
                title = ((try? await Shell.check("git", ["log", "-1", "--format=%s"], cwd: URL(fileURLWithPath: dir))) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
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
            try await Git.push(dir, branch: branch)
            let url = try await GitHub.create(title: title, body: prBody, base: base, draft: draft, in: dir)
            let n = Int(url.split(separator: "/").last ?? "") ?? 0
            AppModel.shared.show("Pull request created")
            dismiss(); onCreated(n)
        } catch { self.error = UserError.message(for: error, action: "Create the pull request") }
    }
}

/// The strip under a session's chat: its branch, and either the open pull request or a way to make one.
struct SessionPRBar: View {
    let session: SessionController
    @State private var pr: PullRequest?
    @State private var showCreate = false
    @State private var stackPos: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
            Text(session.meta.branch ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1)
            if let stackPos { Badge(text: stackPos, kind: .accent) }
            if let pr {
                Badge(text: "#\(pr.number)", kind: .accent)
                if pr.autoMerge { Badge(text: "Auto-merge", kind: .ok) }
            }
            Spacer()
            if let pr {
                Button("Review & merge") { Task { await PRCenter.shared.open(repo: session.meta.cwd, environment: session.meta.environment); await PRCenter.shared.select(pr.number); AppDelegate.shared.showManager(pane: .pulls) } }.buttonStyle(Pill(kind: .primary))
            } else {
                Button("Create PR") { showCreate = true }.buttonStyle(Pill(kind: .plain))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7).background(Theme.sidebar.opacity(0.6))
        .task(id: session.meta.branch) { await load() }
        .sheet(isPresented: $showCreate) { CreatePRSheet(dir: session.meta.workingDirectory, env: session.env) { _ in Task { await load() } } }
    }

    private func load() async {
        guard let b = session.meta.branch else { return }
        let out = try? await Exec.with(session.env) { try await Shell.check("gh", ["pr", "list", "--head", b, "--state", "open", "--json", PullRequest.listFields], cwd: URL(fileURLWithPath: session.meta.cwd)) }
        pr = out.flatMap { try? JSONDecoder().decode([PullRequest].self, from: Data($0.utf8)).first }
        let stacks = await Exec.with(session.env) { await Stacks.load(in: session.meta.cwd) }
        if let st = stacks.first(where: { $0.branches.contains { $0.name == b } }), st.branches.count > 1, let i = st.branches.firstIndex(where: { $0.name == b }) { stackPos = "Stack \(i + 1) of \(st.branches.count)" } else { stackPos = nil }
    }
}
