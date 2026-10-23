// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Starts a session with no questions asked: Claude on Sonnet with Full access, in its own worktree on a new branch, in the repository
/// chosen in the side menu. Servers never get Full access, so a repository on a server starts with Edit files.
@MainActor enum QuickSession {
    static func launch() {
        guard let repo = Project.shared.current else {
            // Without a repository there is nothing to match, so the full sheet asks.
            Nav.shared.showNewSession = true; AppDelegate.shared.showManager(pane: .sessions)
            AppModel.shared.show("Choose a repository first, or pick a folder here")
            return
        }
        let ws = Workspace.shared
        let local = repo.environment == nil
        let access: AccessLevel = local ? .fullAccess : .editFiles
        let stamp = DateFormatter(); stamp.dateFormat = "MMdd-HHmm"
        let n = Workspace.NewSession(folder: repo.dir, backend: .claude, model: "sonnet", access: access,
                                     branch: "quick-" + stamp.string(from: .now), useWorktree: true, firstMessage: "", environment: repo.environment)
        func create() {
            Task {
                do { try await ws.create(n); AppDelegate.shared.showManager(pane: .sessions) }
                catch { AppModel.shared.show(AppModel.shared.capture(error, action: "Start the session"), error: true) }
            }
        }
        if access == .fullAccess, ws.policy.requireTouchIDForFullAccess {
            Biometrics.confirm("Start a session that runs without asking") { ok in if ok { create() } }
        } else { create() }
    }
}
