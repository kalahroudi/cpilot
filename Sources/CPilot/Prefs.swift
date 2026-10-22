// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ServiceManagement
import AppKit
import CPilotKit

enum ThemeChoice: String, CaseIterable { case system, light, dark
    var label: String { rawValue.capitalized }
}
enum UpdateChannel: String, CaseIterable { case releases, main
    var label: String { self == .releases ? "Releases" : "Main branch" }
}

/// User preferences, stored in UserDefaults. Add a property here, a `register(defaults:)` entry, and a row in SettingsPane:
/// a preference that has no row in Settings does not exist.
@MainActor @Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme"); applyTheme() } }
    var showDockIcon: Bool { didSet { d.set(showDockIcon, forKey: "showDockIcon"); applyDockIcon() } }
    var notify: Bool { didSet { d.set(notify, forKey: "notify") } }
    var refreshSeconds: Int { didSet { d.set(refreshSeconds, forKey: "refreshSeconds") } }
    var updateChannel: UpdateChannel { didSet { d.set(updateChannel.rawValue, forKey: "updateChannel") } }
    var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    var sidebarCollapsed: Bool { didSet { d.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }
    /// Minutes of silence before a tab's agent process is stopped. The session resumes with full context on the next message.
    /// Sessions as tabs across the top, or as a list down the left.
    var tabsOnSide: Bool { didSet { d.set(tabsOnSide, forKey: "tabsOnSide") } }
    var followSession: Bool { didSet { d.set(followSession, forKey: "followSession") } }
    /// "files" (CPilot notes only) or "engine" (also connect a long-term memory engine over MCP).
    var memoryEngine: String { didSet { d.set(memoryEngine, forKey: "memoryEngine") } }
    var memoryEngineURL: String { didSet { d.set(memoryEngineURL, forKey: "memoryEngineURL") } }
    /// Index finished messages and recall the best matches at the start of a new session.
    var recall: Bool { didSet { d.set(recall, forKey: "recall") } }
    /// Show a recap when you open a session you have been away from.
    var recapAuto: Bool { didSet { d.set(recapAuto, forKey: "recapAuto") } }
    /// Let Claude rewrite recaps in friendlier language (a small, cheap call).
    var recapWithClaude: Bool { didSet { d.set(recapWithClaude, forKey: "recapWithClaude") } }
    /// How much the agent does by itself when turning an idea into a spec and a stack: "step", "plan" or "hands".
    /// Offers "Merge all as admin" on a stack whose pull requests GitHub's rules block.
    var adminMergeAll: Bool { didSet { d.set(adminMergeAll, forKey: "adminMergeAll") } }
    var autoResolveConflicts: Bool { didSet { d.set(autoResolveConflicts, forKey: "autoResolveConflicts") } }
    var specAutonomy: String { didSet { d.set(specAutonomy, forKey: "specAutonomy") } }
    /// A local checkout of SecurityCage (with npm install done), used for scans.
    var securityCagePath: String { didSet { d.set(securityCagePath, forKey: "securityCagePath") } }
    /// Where the local model server answers (mlxplayer by default).
    var localModelURL: String { didSet { d.set(localModelURL, forKey: "localModelURL") } }
    var sleepMinutes: Int { didSet { d.set(sleepMinutes, forKey: "sleepMinutes") } }
    var cloneFolder: String { didSet { d.set(cloneFolder, forKey: "cloneFolder") } }
    var useWorktrees: Bool { didSet { d.set(useWorktrees, forKey: "useWorktrees") } }
    var captureSendTo: String { didSet { d.set(captureSendTo, forKey: "captureSendTo") } }
    var captureHotkey: Bool { didSet { d.set(captureHotkey, forKey: "captureHotkey"); (NSApp?.delegate as? AppDelegate)?.applyHotkey() } }
    var autoMergeDefault: Bool { didSet { d.set(autoMergeDefault, forKey: "autoMergeDefault") } }
    /// Archive a spec by itself when its last task merges.
    var autoArchiveSpecs: Bool { didSet { d.set(autoArchiveSpecs, forKey: "autoArchiveSpecs") } }
    var securityScanOnPR: Bool { didSet { d.set(securityScanOnPR, forKey: "securityScanOnPR") } }
    var notifyChecks: Bool { didSet { d.set(notifyChecks, forKey: "notifyChecks"); if notifyChecks != oldValue { CIWatcher.shared.start() } } }

    /// Launch at login is on by default; the user can turn it off. Backed by SMAppService (Login Items).
    private(set) var launchAtLogin: Bool = false
    private(set) var launchAtLoginError: String?

    private init() {
        d.register(defaults: ["notify": true, "refreshSeconds": 5, "showDockIcon": true, "autoCheckUpdates": true, "sleepMinutes": 10,
                              "cloneFolder": NSHomeDirectory() + "/code", "useWorktrees": false, "captureSendTo": "active", "captureHotkey": true,
                              "autoMergeDefault": false, "recall": true, "specAutonomy": "step", "adminMergeAll": true, "autoResolveConflicts": true, "recapAuto": true, "recapWithClaude": true, "securityScanOnPR": true, "notifyChecks": true, "followSession": true, "autoArchiveSpecs": true])
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = d.bool(forKey: "showDockIcon")
        notify = d.bool(forKey: "notify")
        refreshSeconds = d.integer(forKey: "refreshSeconds")
        sidebarCollapsed = d.bool(forKey: "sidebarCollapsed")
        sleepMinutes = d.integer(forKey: "sleepMinutes")
        localModelURL = d.string(forKey: "localModelURL") ?? SecurityCage.defaultModelURL
        securityCagePath = d.string(forKey: "securityCagePath") ?? ""
        specAutonomy = d.string(forKey: "specAutonomy") ?? "step"
        adminMergeAll = d.bool(forKey: "adminMergeAll")
        autoResolveConflicts = d.bool(forKey: "autoResolveConflicts")
        recapAuto = d.bool(forKey: "recapAuto")
        recapWithClaude = d.bool(forKey: "recapWithClaude")
        recall = d.bool(forKey: "recall")
        memoryEngine = d.string(forKey: "memoryEngine") ?? "files"
        memoryEngineURL = d.string(forKey: "memoryEngineURL") ?? MemoryEngine.defaultURL
        tabsOnSide = d.bool(forKey: "tabsOnSide")
        followSession = d.bool(forKey: "followSession")
        cloneFolder = d.string(forKey: "cloneFolder") ?? NSHomeDirectory() + "/code"
        useWorktrees = d.bool(forKey: "useWorktrees")
        captureSendTo = d.string(forKey: "captureSendTo") ?? "active"
        captureHotkey = d.bool(forKey: "captureHotkey")
        autoMergeDefault = d.bool(forKey: "autoMergeDefault")
        securityScanOnPR = d.bool(forKey: "securityScanOnPR")
        autoArchiveSpecs = d.bool(forKey: "autoArchiveSpecs")
        notifyChecks = d.bool(forKey: "notifyChecks")
        autoCheckUpdates = d.bool(forKey: "autoCheckUpdates")
        updateChannel = UpdateChannel(rawValue: d.string(forKey: "updateChannel") ?? "") ?? .releases
        // First run: opt in to launch at login. After that the user's choice always wins.
        if !d.bool(forKey: "launchAtLoginDefaulted") {
            d.set(true, forKey: "launchAtLoginDefaulted")
            setLaunchAtLogin(true)
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change Login Items: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    /// Applies to every window AND the popover (which needs the explicit nudge in AppDelegate.applyAppearance).
    func applyTheme() {
        NSApp?.appearance = switch theme { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
        (NSApp?.delegate as? AppDelegate)?.applyAppearance()
    }

    /// Dock icon on = regular app (Dock, Cmd-Tab). Off = menu bar only.
    func applyDockIcon() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
