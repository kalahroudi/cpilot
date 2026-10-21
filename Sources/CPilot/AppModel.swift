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
}

/// App-wide state. Data is only refreshed while the popover or the manager window is visible, so an idle app costs nothing.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // Data: replace with the app's own.
    var status = "Ready"
    var updatedAt: Date?
    var loadedOnce = false

    // UI state
    var tasks: [BackgroundTask] = []
    var toast: Toast?
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
        // Do the real reads here, off the main actor (Shell.run is async). Then publish results.
        onStatusChange?(busy ? .busy : .idle)
        loadedOnce = true; updatedAt = .now
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
                AppLog.error(error, context: title)                         // full detail goes to the log only
                let friendly = UserError.message(for: error, action: title)  // the user sees a short, plain sentence
                finish(id, .failed(friendly)); after?(false)
                notify("\(title) failed", body: friendly)
            }
            await refresh()
            try? await Task.sleep(for: .seconds(20))      // drop finished tasks after a while so the list stays small
            tasks.removeAll { $0.id == id && $0.state != .running }
        }
    }

    private func finish(_ id: UUID, _ state: BackgroundTask.State) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state }
        if case .failed(let m) = state { show(m, error: true) } else if let t = tasks.first(where: { $0.id == id }) { show("\(t.title) finished") }
    }

    func show(_ message: String, error: Bool = false) {
        let t = Toast(message: message, isError: error)
        toast = t
        Task { try? await Task.sleep(for: .seconds(error ? 8 : 3.5)); if toast == t { toast = nil } }
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
            // Create first-run resources here (a default profile, a data folder, a config file).
            try AppPaths().ensureDirectories()
        }
    }
}
