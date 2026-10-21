// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit
@preconcurrency import UserNotifications

struct BackgroundTask: Identifiable {
    enum State: Equatable { case running, done, failed(String) }
    let id = UUID()
    var title: String
    var state: State = .running
    var lines: [String] = []
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
    /// When set, the toast offers a "Details" button that opens the error sheet.
    var report: ErrorReport?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// App-wide state. Data is only refreshed while the popover or the manager window is visible, so an idle app costs nothing.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var status: String {
        let ws = Workspace.shared
        if ws.attention > 0 { return "\(ws.attention) need\(ws.attention == 1 ? "s" : "") your approval" }
        if ws.runningCount > 0 { return "\(ws.runningCount) running" }
        return "Ready"
    }
    var github: GitHub.Account?
    var updatedAt: Date?
    var loadedOnce = false

    // UI state
    var tasks: [BackgroundTask] = []
    var toast: Toast?
    /// The failure the global error sheet is showing. Set through `fail`, never directly.
    var errorReport: ErrorReport?
    private var reports: [String: ErrorReport] = [:]
    var setupState = SetupState.detect()

    var onStatusChange: ((StatusIcon.State) -> Void)?
    /// Set by `--snapshot` so screenshots use sample data and nothing is refreshed.
    var demo = false

    private var pollTask: Task<Void, Never>?
    private var popoverVisible = false
    private var managerVisible = false

    var settings: Prefs { Prefs.shared }
    /// True until every prerequisite is met: the app then shows the guided setup instead of empty screens.
    var needsSetup: Bool { !setupState.ready }
    var busy: Bool { tasks.contains { $0.state == .running } }
    var runningTask: BackgroundTask? { tasks.last { $0.state == .running } }

    // MARK: Visibility-driven polling (no timers while nothing is on screen)

    func setPopoverVisible(_ v: Bool) { popoverVisible = v; updatePolling() }
    func setManagerVisible(_ v: Bool) { managerVisible = v; updatePolling() }

    private func updatePolling() {
        let active = popoverVisible || managerVisible
        if active, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(max(2, self?.settings.refreshSeconds ?? 5)))
                }
            }
        } else if !active {
            pollTask?.cancel(); pollTask = nil
        }
    }

    // MARK: Refresh

    func refresh() async {
        if demo { loadedOnce = true; return }
        setupState = SetupState.detect()
        if github == nil || setupState.items.contains(where: { $0.id == "gh" && !$0.isMet }) { github = await GitHub.account() }
        updateStatusIcon()
        loadedOnce = true; updatedAt = .now
        Project.shared.ensureDefault()
        let warm = Project.shared.current; Task { await PRCenter.shared.warm(warm) }
    }

    func updateStatusIcon() {
        let ws = Workspace.shared
        onStatusChange?(ws.attention > 0 ? .attention : busy ? .busy : ws.runningCount > 0 ? .active : .idle)
    }

    // MARK: Background tasks

    /// Runs a long job without blocking the UI. `work` gets a logger; its lines show in the task banner.
    func runTask(_ title: String, notifyDone: Bool = true, after: (@MainActor (Bool) -> Void)? = nil,
                 _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) {
        let task = BackgroundTask(title: title)
        let id = task.id
        tasks.append(task)
        onStatusChange?(.busy)
        Task {
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in
                if let i = AppModel.shared.tasks.firstIndex(where: { $0.id == id }) { AppModel.shared.tasks[i].lines.append(line) } } }
            do {
                try await work(log)
                finish(id, .done); after?(true)
                if notifyDone { notify("\(title) finished") }
            } catch {
                let r = ErrorReport(error, action: title)                   // logged in full; the user sees a short, plain sentence
                let friendly = r.message
                finish(id, .failed(friendly), report: r); after?(false)
                notify("\(title) failed", body: friendly)
            }
            await refresh()
            try? await Task.sleep(for: .seconds(20))      // drop finished tasks after a while so the list stays small
            tasks.removeAll { $0.id == id && $0.state != .running }
        }
    }

    private func finish(_ id: UUID, _ state: BackgroundTask.State, report: ErrorReport? = nil) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state }
        if case .failed(let m) = state { show(m, error: true, report: report) } else if let t = tasks.first(where: { $0.id == id }) { show("\(t.title) finished") }
    }

    func show(_ message: String, error: Bool = false, report: ErrorReport? = nil) {
        let t = Toast(message: message, isError: error, report: report)
        toast = t
        Task { try? await Task.sleep(for: .seconds(report != nil ? 12 : error ? 8 : 3.5)); if toast == t { toast = nil } }
    }

    // MARK: Failures
    // Every failure goes through one of these three: it is logged in full, the user gets a plain sentence, and the details
    // (already redacted) can be read, copied or sent as a GitHub issue from the error sheet.

    /// The user asked for something and it failed: open the error sheet right away.
    func fail(_ error: Error, action: String) {
        guard !Self.isCancellation(error) else { return }
        errorReport = ErrorReport(error, action: action)
    }

    /// Something failed that the user did not directly ask for (a refresh, a prefetch): a toast with a "Details" button.
    func failQuietly(_ error: Error, action: String) {
        guard !Self.isCancellation(error) else { return }
        let r = ErrorReport(error, action: action)
        show(r.message, error: true, report: r)
    }

    /// For views that show the sentence themselves: logs, remembers the report for `ErrorLine`'s "Details" button, returns the sentence.
    func capture(_ error: Error, action: String) -> String {
        let r = ErrorReport(error, action: action)
        if reports.count > 30 { reports.removeAll() }
        reports[r.message] = r
        return r.message
    }

    func report(forMessage m: String) -> ErrorReport? { reports[m] }

    private static func isCancellation(_ e: Error) -> Bool { e is CancellationError || (e as? URLError)?.code == .cancelled }

    func showDetails(_ r: ErrorReport) {
        errorReport = r
        toast = nil
        AppDelegate.shared.showManager()   // the sheet lives in the Manager window; from the popover this brings it forward
    }

    func notify(_ title: String, body: String = "") {
        guard settings.notify, Bundle.main.bundleIdentifier != nil else { return }   // a bare `swift run` binary cannot post
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent(); c.title = title; c.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    // MARK: First-run setup: automate everything that can be, explain the rest

    func setUpEverything() {
        let state = SetupState.detect()
        runTask("Setting up CPilot") { log in
            if !state.brewFormulae.isEmpty {
                guard state.homebrewPresent else { throw ShellError.failed(command: "setup", status: 1, stderr: "Homebrew is needed first. Install it, then try again.") }
                log("Installing \(state.brewFormulae.joined(separator: ", ")) with Homebrew…")
                try await SetupState.installMissing(state.brewFormulae, onLine: log)
            }
            try AppPaths().ensureDirectories()
        }
    }
}
