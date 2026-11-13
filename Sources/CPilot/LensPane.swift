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

    func start() {
        guard timer == nil else { return }
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
                Text("\(LensFormat.tokens(u.lastContext)) context · \(LensFormat.percent(u.cacheHitRate)) cached")
                    .font(.system(size: 11)).foregroundStyle(heavy ? Theme.warn : .secondary)
            }.buttonStyle(.plain)
             .help(heavy ? "This conversation is large: every call re-reads all of it. A fresh session with a summary costs far less." : "Context sent with each call, and how much of it came from the cache. Open Context Lens for the detail.")
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
                    if rows.isEmpty { Text(lens.loading ? "Reading transcripts…" : "No Claude Code use found in this period.").foregroundStyle(.secondary).font(.system(size: 12.5)) }
                    ForEach(rows.prefix(40), id: \.session) { u in row(u) }
                    Text("Cost is what the same tokens would cost on the API; a Max plan is not billed per token. Cache hit counts cache writes as billed input.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.task { lens.refresh() }
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
                    Badge(text: "\(LensFormat.percent(u.cacheHitRate)) cached", kind: (u.cacheHitRate ?? 1) < 0.8 ? .warn : .neutral)
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
                Text("\(u.coldStarts) pause\(u.coldStarts == 1 ? "" : "s") longer than 5 minutes let the cache expire; the next call wrote \(LensFormat.tokens(u.rewrittenAfterGaps)) tokens again.").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if u.peakContext >= UsageMetrics.forkThreshold {
                Text("The context passed \(LensFormat.tokens(UsageMetrics.forkThreshold)). Every call after that re-read all of it; a fresh session started from a summary would have cost a fraction.").font(.system(size: 12)).foregroundStyle(Theme.warn)
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
