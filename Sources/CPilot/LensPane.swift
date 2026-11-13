// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Context Lens: where a session's usage goes. Reads Claude Code's transcripts into a local ledger (sizes and names only) and keeps it current.
@MainActor @Observable
final class UsageLens {
    static let shared = UsageLens()
    let store = UsageStore()
    /// Summaries by Claude session id, for the last 30 days.
    private(set) var summaries: [String: SessionUsage] = [:]
    private(set) var loading = false
    private(set) var updatedAt: Date?
    private var timer: Timer?
    let changes = ChangeLog()

    /// Notes the usage settings now in effect, so a card can compare sessions from before and after.
    func noteSettings() {
        changes.record("autocompactUnattended", Prefs.shared.autocompactUnattended)
        changes.record("autocompactYours", Prefs.shared.autocompactYours)
    }

    func start() {
        guard timer == nil else { return }
        noteSettings()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in UsageLens.shared.refresh() } }
    }

    /// Reads what the transcripts gained, off the main thread, then updates the numbers.
    func refresh() {
        guard !loading else { return }
        loading = true
        let store = store
        DispatchQueue.global(qos: .utility).async {
            store.sync()
            let list = store.sessions(since: Date().addingTimeInterval(-30 * 86_400))
            Task { @MainActor in
                let lens = UsageLens.shared
                lens.summaries = Dictionary(list.map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a })
                lens.updatedAt = .now; lens.loading = false
            }
        }
    }

    /// The numbers for a CPilot session: Claude's own id for it is what its transcript is named after.
    func usage(for meta: SessionMeta) -> SessionUsage? { meta.remoteId.flatMap { summaries[$0] } }

    /// What to act on for this session now.
    func alerts(for meta: SessionMeta) -> [LensAlert] { usage(for: meta).map { LensAlerts.alerts(for: $0) } ?? [] }

    /// Repeat reads the read-once guard refused since `since`, and the most it kept out of the conversations (an agent that insists is let through, so it is an upper bound).
    func readOnceSaved(since: Date) -> (refused: Int, chars: Int) {
        guard let text = try? String(contentsOf: AppPaths().root.appendingPathComponent("read-once.jsonl"), encoding: .utf8) else { return (0, 0) }
        var n = 0, chars = 0
        for line in text.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let ts = o["ts"] as? Double, Date(timeIntervalSince1970: ts) >= since, o["blocked"] == nil else { continue }
            n += 1; chars += o["saved"] as? Int ?? 0
        }
        return (n, chars)
    }

    /// Reads of secret-holding files the guard refused since `since`.
    func sensitiveBlocked(since: Date) -> Int {
        guard let text = try? String(contentsOf: AppPaths().root.appendingPathComponent("read-once.jsonl"), encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { line in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let ts = o["ts"] as? Double else { return false }
            return o["blocked"] as? String == "sensitive" && Date(timeIntervalSince1970: ts) >= since
        }.count
    }

    func totals(since: Date) -> (calls: Int, cost: Double, read: Int, write: Int, input: Int, output: Int) {
        summaries.values.filter { $0.last >= since }.reduce((0, 0.0, 0, 0, 0, 0)) { ($0.0 + $1.calls, $0.1 + ($1.cost ?? 0), $0.2 + $1.cacheRead, $0.3 + $1.cacheWrite, $0.4 + $1.input, $0.5 + $1.output) }
    }
}

enum LensFormat {
    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
    static func percent(_ r: Double?) -> String { r.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
    static func money(_ c: Double?) -> String { c.map { $0 >= 100 ? String(format: "$%.0f", $0) : String(format: "$%.2f", $0) } ?? "n/a" }
}

/// What the header shows for the session on screen: how full its context is and how well the cache is holding.
struct LensChip: View {
    let session: SessionController
    let lens = UsageLens.shared
    var body: some View {
        if let u = lens.usage(for: session.meta), u.calls > 0 {
            let heavy = u.lastContext >= UsageMetrics.forkThreshold
            Button { Nav.shared.pane = .lens } label: {
                Text("\(LensFormat.tokens(u.lastContext)) context · \(LensFormat.percent(u.cacheHitRate)) from cache")
                    .font(.system(size: 11)).foregroundStyle(heavy ? Theme.warn : .secondary)
            }.buttonStyle(.plain)
             .help(heavy ? "This conversation is large: every call re-reads all of it. A fresh session with a summary costs far less." : "Context sent with each call, and the share of what was sent that came from the cache (a hit, at a tenth of the price). A high share does not make a large context cheap. Open Context Lens for the detail.")
        }
    }
}

/// Shown above the chat when the conversation has grown large or has gone cold, with the way out: carry on from a summary.
struct LensBanner: View {
    let session: SessionController
    let lens = UsageLens.shared
    @State private var dismissed: Set<LensAlert.Kind> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let a = lens.alerts(for: session.meta).first(where: { ($0.kind == .contextHigh || $0.kind == .cacheCold) && !dismissed.contains($0.kind) }), session.meta.backend.kind == .claude {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Theme.warn)
                    Text(a.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue lean") { _ = Workspace.shared.fork(session, lean: true) }.buttonStyle(Pill(kind: .primary)).disabled(session.isBusy)
                        .help(session.isBusy ? "Wait for this turn to finish" : "Start a new session from a summary of this one")
                    Button("Not now") { dismissed.insert(a.kind) }.buttonStyle(Pill(kind: .plain))
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.warnSoft)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }
            }
        }
    }
}

struct LensPane: View {
    let lens = UsageLens.shared
    @State private var window = 7
    @State private var selected: String?

    private var since: Date { Date().addingTimeInterval(-Double(window) * 86_400) }
    private var rows: [SessionUsage] { lens.summaries.values.filter { $0.last >= since }.sorted { ($0.cost ?? 0) > ($1.cost ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Context Lens", subtitle: lens.updatedAt.map { "Read from Claude Code's transcripts on this Mac. Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Reading transcripts…") {
                Picker("", selection: $window) { Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    totalsCard
                    originCard
                    sentCard
                    effectCard("Did it help? Unattended sessions", key: "autocompactUnattended", origins: ["Chief pilot", "Reviewers", "Testers", "Spec tasks"])
                    effectCard("Did it help? Your sessions", key: "autocompactYours", origins: ["You, in CPilot"])
                    if rows.isEmpty { Text(lens.loading ? "Reading transcripts…" : "No Claude Code use found in this period.").foregroundStyle(.secondary).font(.system(size: 12.5)) }
                    ForEach(rows.prefix(40), id: \.session) { u in row(u) }
                    Text("Cost is what the same tokens would cost on the API; a Max plan is not billed per token. From cache is the cache hit rate: reads divided by reads, writes and uncached input. A hit still costs a tenth of an uncached token, so a large context is expensive even at 98%.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.task { lens.noteSettings(); lens.refresh() }
    }

    private var totalsCard: some View {
        let t = lens.totals(since: since)
        let hit = UsageMetrics.hitRate(read: t.read, write: t.write, input: t.input)
        return HStack(alignment: .top, spacing: 28) {
            stat("Calls", "\(t.calls)")
            stat("Cached reads", LensFormat.tokens(t.read))
            stat("Cache hit", LensFormat.percent(hit))
            stat("Output", LensFormat.tokens(t.output))
            stat("API-equivalent", LensFormat.money(t.cost))
            Spacer()
        }.card(padding: 14)
    }

    /// Whether a setting helped: sessions that started before it took effect against those that started after, for the kind of session it applies to.
    @ViewBuilder private func effectCard(_ title: String, key: String, origins: Set<String>) -> some View {
        if let change = lens.changes.latest(key), change.value > 0 {
            let list = lens.summaries.values.filter { u in origins.contains(UsageOrigin.label(Workspace.shared.sessions.first { $0.remoteId == u.session })) }
            let r = BeforeAfter.compare(Array(list), since: change.date)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Compaction at \(LensFormat.tokens(change.value)) since \(change.date.formatted(date: .abbreviated, time: .omitted)). Sessions of 20 calls or more.").font(.system(size: 12))
                if r.enough, let peak = r.peakChange {
                    Text("Median peak context \(LensFormat.tokens(r.before.medianPeakContext)) → \(LensFormat.tokens(r.after.medianPeakContext)) (\(Int((peak * 100).rounded()))%). Above 200k: \(Int(r.before.shareAbove * 100))% → \(Int(r.after.shareAbove * 100))% of sessions. Mean API-equivalent cost per session \(LensFormat.money(r.before.meanCost)) → \(LensFormat.money(r.after.meanCost)).")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Retries and gate failures are not compared yet, so check a drop in cost has not come with more rework.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Text("Not enough data yet: it needs \(BeforeAfter.minimumSessions) such sessions on each side and has \(r.before.sessions) before and \(r.after.sessions) after.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.card(padding: 14)
        }
    }

    /// What was read into conversations in this period: how much file content went to the model provider, how much of it was a repeat, and any secrets.
    private var sentCard: some View {
        let reads = lens.store.reads(since: since)
        let report = ReadReport(reads)
        let sessions = Set(reads.compactMap { r in r.target.flatMap { SensitivePaths.isSensitive($0) ? r.session : nil } })
        return VStack(alignment: .leading, spacing: 6) {
            Text("File content sent to the model").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(report.files.count) distinct files read in \(report.totalReads) reads, about \(LensFormat.tokens(report.totalChars / 4)) tokens. Only files the agent reads leave this Mac (the whole repository never does), but what it read stays in the conversation and is sent again with every later call. \(LensFormat.tokens(report.repeatChars / 4)) tokens were a file and range already read in the same session.")
                .font(.system(size: 12))
            let once = lens.readOnceSaved(since: since)
            if once.refused > 0 { Text("Read once refused \(once.refused) repeat read\(once.refused == 1 ? "" : "s"), up to \(LensFormat.tokens(once.chars / 4)) tokens kept out of conversations (each would also have been sent again with every later call).").font(.system(size: 12)).foregroundStyle(Theme.ok) }
            let blocked = lens.sensitiveBlocked(since: since)
            if blocked > 0 { Text("\(blocked) read\(blocked == 1 ? "" : "s") of keys or secrets refused before anything was sent.").font(.system(size: 12)).foregroundStyle(Theme.ok) }
            if report.sensitive.isEmpty { Text("No keys, tokens or environment files were read.").font(.system(size: 12)).foregroundStyle(.secondary) }
            else {
                Text("Sensitive files read, now in \(sessions.count) conversation\(sessions.count == 1 ? "" : "s") sent to the provider: " + report.sensitive.prefix(6).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") + (report.sensitive.count > 6 ? " and \(report.sensitive.count - 6) more" : "") + ".")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warn)
            }
        }.card(padding: 14)
    }

    private var originCard: some View {
        let list = lens.summaries.values.filter { $0.last >= since }
        let split = UsageOrigin.split(Array(list)) { id in Workspace.shared.sessions.first { $0.remoteId == id } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Who started it").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(split, id: \.origin) { o in
                HStack { Text(o.origin).font(.system(size: 12.5)); Spacer(); Text("\(o.sessions) session\(o.sessions == 1 ? "" : "s") · \(o.calls) calls").font(.system(size: 11.5)).foregroundStyle(.secondary); Text(LensFormat.money(o.cost)).font(.system(size: 12, weight: .semibold)).frame(width: 60, alignment: .trailing) }
            }
        }.card(padding: 14)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value).font(.system(size: 18, weight: .semibold)); Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }
    }

    private func title(_ u: SessionUsage) -> String {
        if let m = Workspace.shared.sessions.first(where: { $0.remoteId == u.session }) { return m.title }
        return u.cwd.isEmpty ? String(u.session.prefix(8)) : URL(fileURLWithPath: u.cwd).lastPathComponent + " · " + String(u.session.prefix(8))
    }

    @ViewBuilder private func row(_ u: SessionUsage) -> some View {
        let open = selected == u.session
        VStack(alignment: .leading, spacing: 8) {
            Button { selected = open ? nil : u.session } label: {
                HStack(spacing: 10) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(title(u)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    if u.peakContext >= UsageMetrics.forkThreshold { Badge(text: "peak \(LensFormat.tokens(u.peakContext))", kind: .warn) } else { Badge(text: "peak \(LensFormat.tokens(u.peakContext))") }
                    Badge(text: "\(LensFormat.percent(u.cacheHitRate)) from cache", kind: (u.cacheHitRate ?? 1) < 0.8 ? .warn : .neutral)
                    Text("\(u.calls) calls").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(LensFormat.money(u.cost)).font(.system(size: 11.5, weight: .semibold)).frame(width: 56, alignment: .trailing)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { detail(u) }
        }.card(padding: 10)
    }

    @ViewBuilder private func detail(_ u: SessionUsage) -> some View {
        let big = UsageMetrics.biggestResults(lens.store.tools(session: u.session))
        VStack(alignment: .leading, spacing: 6) {
            Text("\(u.model) · \(u.first.formatted(date: .abbreviated, time: .shortened)) to \(u.last.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Read \(LensFormat.tokens(u.cacheRead)) from the cache, wrote \(LensFormat.tokens(u.cacheWrite)), sent \(LensFormat.tokens(u.input)) uncached, produced \(LensFormat.tokens(u.output)). Context now \(LensFormat.tokens(u.lastContext)), peak \(LensFormat.tokens(u.peakContext)).").font(.system(size: 12))
            if u.coldStarts > 0 {
                Text("\(u.coldStarts) pause\(u.coldStarts == 1 ? "" : "s") longer than \(Int(u.cacheLife / 60)) minutes let the cache expire; the next call wrote \(LensFormat.tokens(u.rewrittenAfterGaps)) tokens again.").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if u.peakContext >= UsageMetrics.forkThreshold {
                Text("The context passed \(LensFormat.tokens(UsageMetrics.forkThreshold)). Every call after that re-read all of it; a fresh session started from a summary would have cost a fraction.").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            let report = ReadReport(lens.store.tools(session: u.session))
            if report.totalReads > 0 {
                Text("Files read into this conversation: \(report.files.count) files, \(report.totalReads) reads, about \(LensFormat.tokens(report.totalChars / 4)) tokens" + (report.repeatReads > 0 ? "; \(report.repeatReads) repeated a read already made (about \(LensFormat.tokens(report.repeatChars / 4)) tokens)." : "."))
                    .font(.system(size: 12))
                ForEach(report.files.prefix(4), id: \.path) { f in
                    HStack { Text((f.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.head); Spacer(); Text("\(f.reads)× · ~\(LensFormat.tokens(f.chars / 4)) tokens").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                if !report.sensitive.isEmpty { Text("Read a sensitive file: " + report.sensitive.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.warn) }
            }
            if !big.isEmpty {
                Text("Largest tool results (roughly 4 characters per token)").font(.system(size: 11, weight: .semibold)).padding(.top, 2)
                ForEach(big, id: \.name) { b in
                    HStack { Text(b.name).font(.system(size: 12)); Spacer(); Text("\(b.calls) calls · ~\(LensFormat.tokens(b.chars / 4)) tokens").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
