// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import CPilotKit

// MARK: Updates

struct UpdatesView: View {
    let u = Updater.shared
    let prefs = Prefs.shared

    var body: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("This build") {
                SettingRow("Version", "From \(u.build.repo) · branch \(u.build.branch)") { Text("\(u.build.version) · \(u.build.shortCommit)\(u.build.isDirty ? " (modified)" : "")").font(.system(size: 12.5, design: .monospaced)) }
                SettingRow("Update channel", "Releases: signed disk images, the safe default. Main branch: also offers a build of the newest commit (needs Xcode command line tools).") { Segmented(options: UpdateChannel.allCases.map { ($0, $0.label) }, selection: $p.updateChannel) }
                SettingRow("Check automatically", "Once a day at most, when the app starts. Nothing runs in between.") { Toggle("", isOn: $p.autoCheckUpdates).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    statusLine
                    Spacer()
                    Button(u.phase == .checking ? "Checking…" : "Check for updates") { Task { await u.check() } }.buttonStyle(Pill()).disabled(u.busy)
                    if let info = u.available { Button(info.release != nil ? "Install \(info.label)" : "Build & install \(info.label)") { Task { await u.install() } }.buttonStyle(Pill(kind: .primary)).disabled(u.busy) }
                }
                if case .working(let step) = u.phase {
                    VStack(alignment: .leading, spacing: 6) {
                        if let pr = u.progress { ProgressView(value: pr) } else { ProgressView().controlSize(.small) }
                        Text(step).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if case .failed(let m) = u.phase { Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
                if let n = u.notice { Label(n, systemImage: "arrow.uturn.backward.circle").font(.system(size: 12.5)).foregroundStyle(Theme.warn) }
                if let info = u.available, !info.summaries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(info.release != nil ? "What's new in \(info.label)" : "\(info.aheadBy) new commit\(info.aheadBy == 1 ? "" : "s") on \(u.build.branch)")
                        ForEach(info.summaries, id: \.self) { Text("• \($0)").font(.system(size: 12.5)) }
                    }.padding(.top, 4)
                }
            }.card(padding: 14)
            Text("Releases install a signed disk image: it is downloaded, checked against its SHA-256, verified, swapped in after the app quits, and rolled back automatically if the new version doesn't start. Without a release, the app can build the newest commit of \(u.build.branch) (needs Xcode command line tools).").font(.system(size: 12)).foregroundStyle(.secondary)
            if !u.log.isEmpty || !u.savedLog.isEmpty {
                DisclosureGroup("Update log") {
                    ScrollView { Text((u.log.isEmpty ? u.savedLog : u.log).suffix(80).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.85)).frame(maxWidth: .infinity, alignment: .leading).padding(10).textSelection(.enabled) }
                        .frame(height: 150).background(Theme.terminal, in: RoundedRectangle(cornerRadius: 8))
                }.font(.system(size: 12.5))
            }
        }.frame(maxWidth: 720)
    }

    @ViewBuilder private var statusLine: some View {
        switch u.status {
        case .upToDate?: Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .available(let i)?: Label("\(i.label) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        case .notComparable(let why)?: Label(why, systemImage: "info.circle").foregroundStyle(.secondary)
        case nil: Text(u.isBundled ? "Not checked yet" : "Updates work from the installed app, not a development build.").foregroundStyle(.secondary)
        }
    }
}

