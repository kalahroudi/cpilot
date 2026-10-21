import SwiftUI
import AppKit
import CPilotKit

/// Shown when something fails: the plain message, the technical detail to read or copy, and an opt-in way to report it.
struct ErrorReportSheet: View {
    let report: ErrorReport
    @Environment(\.dismiss) private var dismiss
    @State private var showDetail = true
    @State private var sending = false
    @State private var sentURL: URL?
    @State private var note: String?
    @State private var confirm = false

    private var version: String { BuildInfo.current.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(report.message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger)
            DisclosureGroup("Technical details", isExpanded: $showDetail) {
                ScrollView {
                    Text(report.detail).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 150).background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.detail, forType: .string)
                    note = "Copied."
                }.buttonStyle(Pill(kind: .plain))
                Button("Show full log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }.buttonStyle(Pill(kind: .plain))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
            }
            Divider()
            if let sentURL {
                HStack { Label("Reported. Thank you.", systemImage: "checkmark.circle.fill"); Link("View issue", destination: sentURL) }
                    .font(.system(size: 12.5))
            } else if confirm {
                Text("This will create a public issue on github.com/\(IssueReporter.repo) from your GitHub account, containing the action, the app version and the technical details above (home folder and tokens removed). Nothing else is sent.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Not now") { confirm = false }.buttonStyle(Pill(kind: .plain))
                    Button { Task { await send() } } label: { if sending { ProgressView().controlSize(.small) } else { Text("Send report") } }
                        .buttonStyle(Pill(kind: .primary)).disabled(sending)
                }
            } else {
                HStack {
                    Text("Help fix this by reporting it to the developers.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Report issue…") { confirm = true }.buttonStyle(Pill(kind: .plain))
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 540)
    }

    private func send() async {
        sending = true; defer { sending = false }
        do { sentURL = try await IssueReporter.submit(report, version: version) }
        catch {
            // gh missing or not signed in: open a prefilled issue page; the user still decides whether to submit it.
            if let u = IssueReporter.prefilled(report, version: version) { NSWorkspace.shared.open(u); note = "Opened a prefilled issue in your browser."; confirm = false }
            else { note = "Couldn't send the report. Copy the details instead." }
        }
    }
}

/// An inline failure message. When the full report is known (the text came from `AppModel.capture`) it offers "Details".
struct ErrorLine: View {
    let text: String
    @State private var detail: ErrorReport?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.danger)
            if let r = AppModel.shared.report(forMessage: text) { Button("Details") { detail = r }.buttonStyle(.link).font(.system(size: 12)) }
        }
        .sheet(item: $detail) { ErrorReportSheet(report: $0) }
    }
}
