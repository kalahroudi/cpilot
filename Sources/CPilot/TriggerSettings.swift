// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Settings, Triggers: work that starts by itself.
struct TriggerSettings: View {
    let engine = TriggerEngine.shared
    @State private var editing: Trigger?
    @State private var told: [String: String] = [:]

    private func repoName(_ dir: String) -> String { URL(fileURLWithPath: dir).lastPathComponent }

    var body: some View {
        let _ = engine.version
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Triggers") {
                SettingRow("Start work by itself", "A schedule, an issue of yours that gets a label, or a pull request of yours that fails its checks starts the chief pilot (or one session) with no one at the keyboard. CPilot must be running. It looks once a minute and asks GitHub at most every five minutes.") {
                    Button("Add trigger") { editing = Trigger(name: "", repo: Self.repos.first?.dir ?? "", kind: .schedule) }.buttonStyle(Pill(kind: .primary))
                }
                if engine.store.triggers.isEmpty { SettingRow("No triggers yet", "Try a weekly dependency check, or the label \"cpilot\" on an issue you write.") { EmptyView() } }
                ForEach(engine.store.triggers) { t in
                    SettingRow(t.name.isEmpty ? "Untitled" : t.name, detail(t), error: t.problem) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { t.enabled }, set: { var c = t; c.enabled = $0; engine.save(c) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                            AsyncButton("Run now") { let o = await engine.runNow(t.id); told[t.id] = o.message }.buttonStyle(Pill(kind: .plain))
                            Button("Edit") { editing = t }.buttonStyle(Pill(kind: .plain))
                        }
                    }
                }
            }
            SettingsGroup("Recent runs") {
                let runs = Array(engine.store.runs.prefix(8))
                if runs.isEmpty { SettingRow("Nothing has run yet", nil) { EmptyView() } }
                ForEach(runs) { r in
                    SettingRow(r.name, "\(r.what)" + (r.detail.isEmpty ? "" : "\n\(r.detail)"), error: r.outcome == .failed ? "Failed" : nil) {
                        Text(r.ts.formatted(.relative(presentation: .named))).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsGroup("Limits") {
                SettingRow("What keeps it safe", "At most \(TriggerStore.hourlyLimit) runs an hour, and ten minutes between runs of one trigger. An issue only counts if you wrote it, because issue text goes to an agent that can push and merge. A failing pull request gets \(TriggerPolicy.maxAttempts) fix attempts, then it is left to you. What a trigger starts follows your other settings: the chief pilot's setting for push and merge, and the Specs access level for one-off sessions (Settings, Access).") { EmptyView() }
            }
        }
        .sheet(item: $editing) { t in TriggerEditor(trigger: t, isNew: !engine.store.triggers.contains { $0.id == t.id }) }
    }

    static var repos: [PRCenter.Repo] { Project.shared.repos().filter { $0.environment == nil } }

    private func detail(_ t: Trigger) -> String {
        var lines = ["\(t.summary()) · \(repoName(t.repo))"]
        if let m = told[t.id] ?? engine.notes[t.id], !m.isEmpty { lines.append(m) }
        else if let last = t.lastRun { lines.append("Last ran \(last.formatted(.relative(presentation: .named)))") }
        if t.isFinishedOneOff { lines.append("Done. A one-off runs once; delete it or make a new one.") }
        else if t.kind == .schedule, t.enabled, t.problem == nil { lines.append("Next: " + t.schedule.next(after: t.lastRun ?? t.createdAt).formatted(date: .abbreviated, time: .shortened)) }
        return lines.joined(separator: "\n")
    }
}

struct TriggerEditor: View {
    @State var trigger: Trigger
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    /// The moment of a one-off. A new one starts an hour from now, so the date is never blank.
    private var onceAt: Binding<Date> {
        Binding(get: { trigger.schedule.at ?? Date().addingTimeInterval(3600) }, set: { trigger.schedule.at = $0 })
    }

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: trigger.schedule.hour, minute: trigger.schedule.minute, second: 0, of: Date()) ?? Date() },
                set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); trigger.schedule.hour = c.hour ?? 9; trigger.schedule.minute = c.minute ?? 0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New trigger" : "Edit trigger").font(.system(size: 17, weight: .semibold))
            FormField("Name") { TextField("Weekly dependency check", text: $trigger.name).textFieldStyle(CPField()) }
            FormField("Repository") {
                Dropdown(options: TriggerSettings.repos.map { ($0.dir, URL(fileURLWithPath: $0.dir).lastPathComponent) }, selection: $trigger.repo, placeholder: "Choose a repository")
            }
            FormField("Starts when") {
                Segmented(options: [(Trigger.Kind.schedule, "On a schedule"), (.issueLabel, "Issue labelled"), (.failingChecks, "Checks fail")], selection: $trigger.kind)
            }
            switch trigger.kind {
            case .schedule:
                HStack(alignment: .top, spacing: 12) {
                    FormField("Repeats") {
                        Dropdown(options: Schedule.Frequency.allCases.map { ($0, $0 == .once ? "Once, at a set time" : $0 == .hourly ? "Every few hours" : $0 == .daily ? "Every day" : $0 == .weekdays ? "Weekdays" : "Every week") }, selection: $trigger.schedule.frequency)
                    }
                    if trigger.schedule.frequency == .once {
                        FormField("When") { DatePicker("", selection: onceAt, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                    } else if trigger.schedule.frequency == .hourly {
                        FormField("Every") { Stepper("\(trigger.schedule.everyHours) hours", value: $trigger.schedule.everyHours, in: 1...168) }
                    } else {
                        FormField("At") { DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden() }
                    }
                    if trigger.schedule.frequency == .weekly {
                        FormField("On") {
                            Dropdown(options: Calendar.current.weekdaySymbols.enumerated().map { ($0.offset + 1, $0.element) }, selection: $trigger.schedule.weekday)
                        }
                    }
                }
            case .issueLabel:
                FormField("Label", hint: "Open issues you wrote with this label are picked up, one at a time, and never twice. Other people's issues are ignored.") {
                    TextField("cpilot", text: $trigger.label).textFieldStyle(CPField())
                }
            case .failingChecks:
                Text("When the checks on one of your own open pull requests fail, it looks at the failure and tries to fix it. It tries at most \(TriggerPolicy.maxAttempts) times for one pull request, and leaves pull requests the chief pilot or a reviewer is already working on.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let sid = trigger.sessionId {
                let title = Workspace.shared.sessions.first { $0.id == sid }?.title
                Text("Sends this to \(title.map { "the session \"\($0)\"" } ?? "a session that is gone") instead of starting new work.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                FormField("Then") {
                    Segmented(options: [(Trigger.Action.chief, "Chief pilot carries it through"), (.session, "One session")], selection: $trigger.action)
                }
                Text(trigger.action == .chief ? "The repository's chief pilot gets it as an outcome and takes it to merged pull requests. If it is busy, the trigger waits." : "A new session starts on its own branch in its own worktree.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            FormField(trigger.kind == .schedule ? "What to do" : "Extra instructions (optional)") {
                TextEditor(text: $trigger.prompt).font(.system(size: 13)).frame(minHeight: 80, maxHeight: 130).scrollContentBackground(.hidden)
                    .padding(6).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }
            if let p = trigger.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                if !isNew { Button("Delete") { confirmDelete = true }.buttonStyle(Pill(kind: .danger)) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Save") { TriggerEngine.shared.save(trigger); dismiss() }.buttonStyle(Pill(kind: .primary)).disabled(trigger.problem != nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .confirmationDialog("Delete this trigger?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { TriggerEngine.shared.remove(trigger.id); dismiss() }
        } message: { Text("What it already started is not touched.") }
    }
}
