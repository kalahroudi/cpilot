// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
/// The search box filters every tab at once: a row stays when its name or explanation has every word, a whole group stays when its title does.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    @State private var query = ""
    @State private var found = 1
    enum Tab: Hashable { case general, sessions, access, triggers, remote, github, agents, updates, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                SearchBox(prompt: "Search settings", text: $query).frame(width: 240)
            } tabs: {
                if !searching {
                    TabBar(tabs: [(Tab.general, "General"), (Tab.sessions, "Sessions"), (Tab.access, "Access"), (Tab.triggers, "Triggers"), (Tab.remote, "Remote"), (Tab.github, "GitHub"), (Tab.agents, "Agents"), (Tab.updates, "Updates"), (Tab.about, "About")], selection: $tab)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if searching {
                        general; sessions; AccessSettings(); TriggerSettings(); RemoteSettings(); GitHubSettings(); AgentSettings()
                        if found == 0 { Text("No setting matches \"\(query)\".").foregroundStyle(.secondary).font(.system(size: 13)).padding(.top, 8) }
                    } else {
                        switch tab {
                        case .general: general
                        case .sessions: sessions
                        case .access: AccessSettings()
                        case .triggers: TriggerSettings()
                        case .remote: RemoteSettings()
                        case .github: GitHubSettings()
                        case .agents: AgentSettings()
                        case .updates: UpdatesView()
                        case .about: about
                        }
                    }
                }
                .environment(\.settingsQuery, query.trimmingCharacters(in: .whitespaces))
                .onPreferenceChange(SettingsMatchCount.self) { found = $0 }
                .padding(22).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("CPilot \(BuildInfo.current.version) · github.com/kalahroudi/cpilot"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

    /// The app itself: how it starts, looks and tells you things.
    private var general: some View {
        @Bindable var p = prefs
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Startup") {
                SettingRow("Launch at login", "Starts in the menu bar and uses no CPU until you open it.", error: prefs.launchAtLoginError) { toggle(Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })) }
            }
            SettingsGroup("Appearance") {
                SettingRow("Theme", "Applies to the window and the menu bar popover.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                SettingRow("Dock icon", "Keep CPilot in the Dock as well as the menu bar.") { toggle($p.showDockIcon) }
                SettingRow("Sessions as", "Tabs across the top, or a list down the left grouped by project.") { Segmented(options: [(false, "Tabs"), (true, "Side list")], selection: $p.tabsOnSide) }
            }
            SettingsGroup("Notifications") {
                SettingRow("Notify me", "When a session needs approval or finishes while CPilot is in the background.") { toggle($p.notify) }
                SettingRow("Pull request checks", "Tells you when the checks on your open pull requests pass or fail. One request per repository: every minute while checks run, every ten minutes otherwise.") { toggle($p.notifyChecks) }
            }
            SettingsGroup("Performance") {
                SettingRow("Nothing runs while hidden", "No polling or timers while the popover and window are closed, except the pull request check watcher. Sleeping tabs hold no memory.") { Badge(text: "always on", kind: .ok) }
                SettingRow("App memory", "How much memory CPilot uses right now.") { Text(AppMemory.footprint).font(.system(size: 12.5)).foregroundStyle(.secondary) }
            }
        }
    }

    /// Working with agents: sessions, what they remember, specs and capture.
    private var sessions: some View {
        @Bindable var p = prefs
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Sessions") {
                SettingRow("Follow the session", "Opening a session makes its repository the active one, so Specs, Stacks and Pull requests show the repository you are working in.") { toggle($p.followSession) }
                SettingRow("Isolate new sessions in a worktree", "Each session on a new branch gets its own copy of the files, so parallel sessions never collide.") { toggle($p.useWorktrees) }
                SettingRow("Put idle tabs to sleep", "Stops an idle session's agent after this long. It resumes with its full context when you send the next message.") {
                    Segmented(options: [(5, "5 min"), (10, "10 min"), (30, "30 min"), (240, "4 h")], selection: $p.sleepMinutes)
                }
                SettingRow("Recap when you return", "Opening a session you have been away from for a while shows where things stand: the latest ask, what got done, and anything waiting on you.") { toggle($p.recapAuto) }
                if prefs.recapAuto { SettingRow("Let Claude write recaps", "A small, cheap call that rewrites the recap in a few friendly lines. Off keeps it to the plain version built on your Mac.") { toggle($p.recapWithClaude) } }
            }
            SettingsGroup("Sessions") {
                SettingRow("Suggest your next message", "After each turn Claude drafts a reply to what the agent just said, shown faintly in the message box. Press Tab to use it. A small, cheap call.") { toggle($p.suggestPrompts) }
            }
            SettingsGroup("Saving usage") {
                SettingRow("Read a file once", "When an agent asks to read a file that is already in its conversation and has not changed since, CPilot tells it so instead of sending the same code again. Every copy stays in the conversation and is sent again with every later call; on measured use 42% of what the Read tool returned was a repeat. It lets the call through if the file changed, the conversation was compacted, or the agent asks a second time. Applies to sessions on this Mac when they next start.") { toggle($p.readOnce) }
            }
            SettingsGroup("Keeping secrets out") {
                SettingRow("Do not read keys and secrets", "Agents are refused a read of files that hold secrets (.env, private keys, .npmrc, credentials, certificates) before anything is sent to the model provider, and told to work without them. What an agent reads is sent to the provider and stays in the conversation, so for key codebases this keeps secrets out. Only plain reads are covered (the Read tool, cat, sed, head, tail); an agent that runs a program that prints a secret is not stopped. Applies to sessions on this Mac when they next start.") { toggle($p.blockSensitiveReads) }
            }
            SettingsGroup("Limits for unattended work") {
                SettingRow("Agents working at once", "Triggers, and the tasks and reviewers the chief pilot starts, wait while this many agents are working. Sessions you start yourself are never held.") {
                    Segmented(options: [(2, "2"), (4, "4"), (8, "8"), (0, "No limit")], selection: $p.maxAgents)
                }
                SettingRow("Compact long conversations (unattended)", "The chief pilot, tasks and reviewers run for hours and every call re-reads the whole conversation. Claude summarizes theirs when it reaches this size. On your own usage, calls above 200k tokens were most of what was processed. Takes effect when a session next starts.") {
                    Segmented(options: [(150_000, "150k"), (200_000, "200k"), (300_000, "300k"), (0, "Claude's default")], selection: $p.autocompactUnattended)
                }
                SettingRow("Compact long conversations (yours)", "The same for sessions you drive yourself. Off by default: summarizing can lose detail you are relying on, and the banner offers Continue lean instead.") {
                    Segmented(options: [(0, "Off"), (200_000, "200k"), (300_000, "300k"), (500_000, "500k")], selection: $p.autocompactYours)
                }
                SettingRow("Carry on after Claude's usage limit resets", "When the limit is reached (\"resets 2am\"), work that starts by itself waits for the reset instead of asking again and again, and the chief pilot and CPilot's own workers carry on when it resets. Your own sessions are never held, and you can carry on early from the banner. Off still holds the work, but nothing resumes by itself.") { toggle($p.resumeAfterLimit) }
                SettingRow("Daily budget", "Once agents have spent this much today (all sessions count), work that starts by itself waits until tomorrow. A turn already under way finishes.") {
                    Segmented(options: [(0, "Off"), (10, "$10"), (25, "$25"), (50, "$50"), (100, "$100")], selection: $p.dailyBudget)
                }
                SettingRow("Most one task may spend", "A spec task that has spent this much stops and asks you, instead of being sent back and nudged for ever. Say anything to its session and it gets the same amount again. Only what the agent reports counts, so an agent that reports no cost is held by the two limits below.") {
                    Segmented(options: [(0, "Off"), (5, "$5"), (10, "$10"), (25, "$25"), (50, "$50")], selection: $p.taskDollars)
                }
                SettingRow("Most turns for one task", "How many times the agent answers before the task stops and asks you.") {
                    Segmented(options: [(0, "Off"), (20, "20"), (40, "40"), (80, "80")], selection: $p.taskTurns)
                }
                SettingRow("Most working time for one task", "How long the agent may work on one task, counting only the time it is answering.") {
                    Segmented(options: [(0, "Off"), (30, "30 min"), (60, "1 h"), (120, "2 h"), (240, "4 h")], selection: $p.taskMinutes)
                }
                SpendRow()
            }
            SettingsGroup("Cleanup") {
                SettingRow("Clean up delivered work", "When the pull request of a task or reviewer the chief pilot started is merged or closed, its checkout is removed and the session is put away. Work that is not committed, or is on no remote, is never removed. Sessions you started yourself are never touched.") { toggle($p.cleanUp) }
                SettingRow("Keep put-away sessions for", "Put-away sessions of that kind still hold their transcript, which the lessons from a run are read from. After this long they are deleted.") {
                    Segmented(options: [(7, "7 days"), (30, "30 days"), (90, "90 days"), (0, "For ever")], selection: $p.keepArchivedDays)
                }
                CleanupRow()
            }
            SettingsGroup("Specs and stacks") {
                SettingRow("Default autonomy", Autonomy(rawValue: prefs.specAutonomy)?.detail ?? "") {
                    Segmented(options: Autonomy.allCases.map { ($0.rawValue, $0.label) }, selection: $p.specAutonomy)
                }
                SettingRow("Chief pilot", prefs.chiefMode.detail) {
                    Segmented(options: ChiefPilot.Autonomy.allCases.map { ($0.rawValue, $0.label) }, selection: $p.chiefAutonomy)
                }
                SettingRow("Reviewer model", "The model that reviews the pull requests the chief pilot starts. Choosing a different one from the model that wrote the code means the review does not share its blind spots. Default uses the same default as any new session.") {
                    ModelPicker(selection: $p.reviewerModel)
                }
                SettingRow("Tests first", "A separate tester writes each task's tests from the spec, before any code, and the implementer cannot change them. The tester never sees the plan or the code. The gate runs the tester's own copy, so a test cannot be weakened to pass. Off keeps today's way: one session writes both. Risky tasks are those that mention security, money, deletion, migrations, permissions and the like.") {
                    Segmented(options: [("off", "Off"), ("risky", "Risky tasks"), ("all", "Every task")], selection: $p.testFirst)
                }
                if prefs.testFirst != "off" {
                    SettingRow("Tester model", "The model that writes the tests. Choose a different one from the model that writes the code, so the tests do not share its misreadings. Default uses the same default as any new session.") { ModelPicker(selection: $p.testerModel) }
                    SettingRow("Second tester", "A second tester on another model writes its own tests from the same spec, without seeing the first's. Its tests are the held-back set, and where the two testers expect different behavior the spec is ambiguous, so you are asked before any code is written. Empty is off. It needs a different model from the tester's to be independent.") { ModelPicker(selection: $p.secondTesterModel) }
                    SettingRow("Hold some tests back", "The tester keeps about a third of its tests (edge cases, abuse, every setting) out of the implementer's checkout, so the code cannot be fitted to them. Only the gate runs them, and a failure names the requirement, never the test.") { toggle($p.hiddenTests) }
                    SettingRow("Weekly review of the trunk", "Adds a schedule that starts a session every week to attack this repository's main branch against the rules in .cpilot/invariants. It proves each finding with a failing test or a reproduction, on its own branch, and changes nothing on main. You can change or remove the schedule in Triggers.") {
                        AsyncButton("Add the schedule") {
                            guard let r = Project.shared.current, r.environment == nil else { AppModel.shared.show("Open a repository on this Mac first.", error: true); return }
                            let text = (try? await Shell.check("cat", [r.dir + "/.cpilot/invariants"], timeout: 15)) ?? ""
                            let rules = Invariants.parse(text)
                            guard !rules.isEmpty else { AppModel.shared.show("Write the rules that must always hold in .cpilot/invariants first, one per line starting with a dash.", error: true); return }
                            TriggerEngine.shared.store.upsert(Trigger(name: TestFirst.sweepName, repo: r.dir, kind: .schedule, action: .session, prompt: TestFirst.sweepPrompt(invariants: rules), schedule: Schedule(frequency: .weekly, hour: 9, minute: 0, weekday: 2)))
                            AppModel.shared.show("Added: every Monday at 9:00 a session reviews \(r.name) against \(rules.count) rule\(rules.count == 1 ? "" : "s").")
                        }.buttonStyle(Pill(kind: .plain))
                    }
                    SettingRow("Review each spec first", "Before any tests are written, a reviewer looks for gaps in the spec: ambiguity, missing cases, abuse cases, rules from .cpilot/invariants it does not cover. You are asked to approve the spec, with the reasons, unless the review finds nothing and the next setting is on.") { toggle($p.specReview) }
                    if prefs.specReview {
                        SettingRow("Approve a spec by itself when the review finds nothing", "A spec with open questions or findings always waits for you.") { toggle($p.specAutoApprove) }
                        SettingRow("Spec review model", "Empty uses the reviewer model.") { ModelPicker(selection: $p.specReviewModel) }
                    }
                }
                SettingRow("Offer \"Merge all as admin\"", "On a stack that GitHub's rules block, merges every open pull request in order past those rules, after one confirmation. Each still needs its checks to pass. Off keeps the one-at-a-time button.") { toggle($p.adminMergeAll) }
                SettingRow("Combine stacks that change the same files", "When open pull requests in different stacks edit the same files, a session combines them into one pull request by itself, checks it builds, and closes the old ones. Off keeps it a button on each stack.") { toggle($p.autoCollapse) }
                SettingRow("Resolve stack conflicts with Claude", "When a restack stops on a conflict, a session starts by itself in a temporary copy to resolve it. Merge all as admin waits for it and carries on. Off keeps it a button.") { toggle($p.autoResolveConflicts) }
                if prefs.autoResolveConflicts { SettingRow("Wait for a conflict up to", "How long Merge all as admin waits for Claude to resolve a conflict before it stops and leaves the conflict card.") {
                    Segmented(options: [(10, "10 min"), (40, "40 min"), (120, "2 h"), (0, "No limit")], selection: $p.conflictWaitMinutes)
                } }
                SettingRow("Archive finished specs", "A spec moves to its archive folder by itself when its last task merges. Archived specs are not read again and can be restored from the Specs list.") { toggle($p.autoArchiveSpecs) }
            }
            SettingsGroup("Memory") {
                SettingRow("Notes", "Plain Markdown notes every session starts with. Always on. Edit them in the Memory screen.") { Badge(text: "always on", kind: .ok) }
                SettingRow("Recall from earlier sessions", "Finished messages are kept in a small local index on this Mac. A new session starts with the best matches for its first message. Nothing is sent anywhere.") { toggle($p.recall) }
                if prefs.recall { RecallStatsRow() }
                SettingRow("Learn from finished runs", "When a chief pilot run is over, CPilot reads what its reviewers caught and what failed, asks Claude (one small call, no tools) for the few lessons worth keeping, and adds them to a note called \"lessons-from-past-runs\" for that repository. Every later session there starts with it. A run with nothing to learn from makes no call. Edit or delete the note in Memory.") { toggle($p.learnLessons) }
                if prefs.learnLessons {
                    SettingRow("Learn from recent runs now", "Looks at the current repository's reviewer reports and failures since the last look, without waiting for a run to end.") {
                        AsyncButton("Learn now") {
                            guard let r = Project.shared.current, r.environment == nil else { AppModel.shared.show("Open a repository on this Mac first.", error: true); return }
                            let o = await LessonLearner.shared.learn(repo: r.dir, manual: true)
                            AppModel.shared.show(o.message, error: { if case .failed = o { return true } else { return false } }())
                        }.buttonStyle(Pill(kind: .plain))
                    }
                }
                SettingRow("Dream over recent sessions", "From time to time, after a few sessions in a repository have finished, CPilot asks Claude (one call, no tools) to look over what they did and propose changes that keep that repository's notes true: add what was learned, fix what is out of date, merge duplicates, remove what no longer holds. Every proposal must quote the sessions word for word, and a quote that is not really there is thrown away. Notes you wrote only ever change when you approve. Nothing is changed without keeping the old text in History.") { toggle($p.dream) }
                if prefs.dream {
                    SettingRow("Let dreams change notes CPilot wrote", "Lessons, notes from agents and earlier dreams can be changed straight away, and you can undo each change in Memory. Turn this off to approve every change yourself.") { toggle($p.dreamAuto) }
                    SettingRow("Dream model", "The model that reads the sessions and writes the proposals. Empty uses Sonnet.") { ModelPicker(selection: $p.dreamModel) }
                    SettingRow("Dream now", "Looks over the current repository's recent sessions without waiting.") {
                        AsyncButton("Dream now") {
                            guard let r = Project.shared.current, r.environment == nil else { AppModel.shared.show("Open a repository on this Mac first.", error: true); return }
                            let o = await Dreamer.shared.dream(repo: r.dir, manual: true)
                            AppModel.shared.show(o.message, error: { if case .failed = o { return true } else { return false } }())
                        }.buttonStyle(Pill(kind: .plain))
                    }
                }
                SettingRow("Long-term memory engine", "Optional. Connects a memory engine over MCP so sessions can recall what earlier sessions learned.") {
                    Segmented(options: [("files", "Off"), ("engine", "On")], selection: $p.memoryEngine)
                }
                if prefs.memoryEngine == "engine" { MemoryEngineRow() }
            }
            SettingsGroup("Capture") {
                SettingRow("Capture shortcut", "Control-Option-Command-C drags out a region of the screen and attaches it to the active session.") { toggle($p.captureHotkey) }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(size: 72)).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPilot").font(.system(size: 18, weight: .semibold))
                    Text("Version \(BuildInfo.current.version) · \(BuildInfo.current.shortCommit)").foregroundStyle(.secondary)
                    Text("A superlight menu bar app for running AI coding sessions.").font(.system(size: 12.5))
                }
            }
            HStack(spacing: 10) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/kalahroudi/cpilot")!)
                Link("Report an issue", destination: URL(string: "https://github.com/kalahroudi/cpilot/issues")!)
                Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }.buttonStyle(.link)
                Link("Website", destination: URL(string: "https://kalahroudi.github.io/cpilot/")!)
            }.font(.system(size: 13))
            Text("Licensed under the Apache License 2.0.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// What the agents cost, by who started the work.
struct SpendRow: View {
    @State private var range = 1
    var body: some View {
        let since = range == 1 ? Guardrails.startOfDay() : Date().addingTimeInterval(-Double(range) * 86_400)
        let totals = Workspace.shared.ledger.totals(since: since)
        let sum = totals.reduce(0) { $0 + $1.cost }
        SettingRow(String(format: "Spent %@: $%.2f", range == 1 ? "today" : "in \(range) days", sum),
                   totals.isEmpty ? "Nothing yet. Each finished turn is counted, by who started the session." : totals.map { String(format: "%@ $%.2f (%@, %d turn%@)", $0.source, $0.cost, Self.duration($0.seconds), $0.turns, $0.turns == 1 ? "" : "s") }.joined(separator: " · ")) {
            Segmented(options: [(1, "Today"), (7, "7 days"), (30, "30 days")], selection: $range)
        }
    }

    static func duration(_ s: Double) -> String { s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : String(format: "%.1f h", s / 3600) }
}

struct RecallStatsRow: View {
    @State private var counts = Workspace.shared.index.counts()
    var body: some View {
        SettingRow("\(counts.notes) notes and \(counts.chats) message chunks indexed", "Secrets such as API keys are removed before anything is stored. Tool output is never stored.") {
            HStack(spacing: 6) {
                Button("Rebuild") { Workspace.shared.rebuildIndex(); counts = Workspace.shared.index.counts() }.buttonStyle(Pill(kind: .plain))
                Button("Forget chats") { Workspace.shared.index.removeAll(source: "chat"); counts = Workspace.shared.index.counts() }.buttonStyle(Pill(kind: .danger))
            }
        }
    }
}

struct MemoryEngineRow: View {
    @State private var up: Bool?
    var body: some View {
        @Bindable var p = Prefs.shared
        VStack(spacing: 0) {
            SettingRow("Engine address", up == nil ? "Checking…" : up == true ? "Reachable. Each project gets its own memory bank." : "Not reachable. Start the engine, then check again.") {
                HStack(spacing: 6) {
                    TextField("http://localhost:8888", text: $p.memoryEngineURL).textFieldStyle(CPField()).frame(width: 190)
                    AsyncButton("Check") { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) }.buttonStyle(Pill(kind: .plain))
                }
            }
            if up == false {
                SettingRow("Start it with Docker", "Copy this into Terminal. It stores data in its own volume and needs a language model key for extracting memories.") { CopyButton(text: MemoryEngine.dockerCommand, label: "Copy command") }
            }
        }.task { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) }
    }
}

/// What the settings search box holds. Rows and groups read it to hide themselves.
private struct SettingsQueryKey: EnvironmentKey { static let defaultValue = "" }
private struct SettingsGroupMatchedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var settingsQuery: String { get { self[SettingsQueryKey.self] } set { self[SettingsQueryKey.self] = newValue } }
    fileprivate var settingsGroupMatched: Bool { get { self[SettingsGroupMatchedKey.self] } set { self[SettingsGroupMatchedKey.self] = newValue } }
}

/// Every visible row adds one, so a group can tell when nothing in it matches and the pane can say so.
struct SettingsMatchCount: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

enum SettingsSearch {
    /// Every word of the query appears in the name or the explanation.
    static func matches(_ query: String, _ title: String, _ detail: String?) -> Bool {
        let hay = (title + " " + (detail ?? "")).lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }
}

struct SettingsGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    @Environment(\.settingsQuery) private var query
    @State private var rows = 1
    init(_ t: String, @ViewBuilder content: () -> C) { title = t; self.content = content() }
    var body: some View {
        let titleMatches = !query.isEmpty && SettingsSearch.matches(query, title, nil)
        let shown = query.isEmpty || titleMatches || rows > 0
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.leading, 4)
            VStack(spacing: 0) { content }.environment(\.settingsGroupMatched, titleMatches).padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
        .onPreferenceChange(SettingsMatchCount.self) { rows = $0 }
        .frame(height: shown ? nil : 0, alignment: .top).clipped().opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
        .padding(.bottom, shown ? 18 : 0)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var error: String?
    var separator = true
    @ViewBuilder var control: Control
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsGroupMatched) private var groupMatched
    init(_ title: String, _ detail: String?, error: String? = nil, separator: Bool = true, @ViewBuilder _ control: () -> Control) { self.title = title; self.detail = detail; self.error = error; self.separator = separator; self.control = control() }
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13))
            if let d = detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Label and control side by side when there is room; the control drops under the label when there is not,
    /// so text never gets squeezed into a sliver.
    var body: some View {
        if query.isEmpty || groupMatched || SettingsSearch.matches(query, title, detail) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    label.frame(minWidth: 190, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                    control.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) { label.frame(maxWidth: .infinity, alignment: .leading); control }
            }
            .padding(.vertical, 10).overlay(alignment: .top) { if separator { Divider().opacity(0.6) } }
            .preference(key: SettingsMatchCount.self, value: 1)
        }
    }
}


/// What the last cleanup did, and a button to run one now.
struct CleanupRow: View {
    let center = CleanupCenter.shared
    var body: some View {
        SettingRow(center.last.map { "Last cleanup: " + $0.headline } ?? "No cleanup yet", center.last?.detail ?? "It runs a minute after CPilot opens, every few hours, and when a chief pilot run ends.") {
            AsyncButton { _ = await center.sweep(manual: true) } label: { Text(center.running ? "Cleaning up…" : "Clean up now") }
                .buttonStyle(Pill(kind: .plain)).disabled(center.running)
        }
    }
}
