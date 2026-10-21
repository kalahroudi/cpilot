// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ServiceManagement
import AppKit

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
    var sleepMinutes: Int { didSet { d.set(sleepMinutes, forKey: "sleepMinutes") } }
    var cloneFolder: String { didSet { d.set(cloneFolder, forKey: "cloneFolder") } }
    var useWorktrees: Bool { didSet { d.set(useWorktrees, forKey: "useWorktrees") } }
    var captureSendTo: String { didSet { d.set(captureSendTo, forKey: "captureSendTo") } }
    var captureHotkey: Bool { didSet { d.set(captureHotkey, forKey: "captureHotkey"); (NSApp?.delegate as? AppDelegate)?.applyHotkey() } }
    var autoMergeDefault: Bool { didSet { d.set(autoMergeDefault, forKey: "autoMergeDefault") } }
    var securityScanOnPR: Bool { didSet { d.set(securityScanOnPR, forKey: "securityScanOnPR") } }

    /// Launch at login is on by default; the user can turn it off. Backed by SMAppService (Login Items).
    private(set) var launchAtLogin: Bool = false
    private(set) var launchAtLoginError: String?

    private init() {
        d.register(defaults: ["notify": true, "refreshSeconds": 5, "showDockIcon": true, "autoCheckUpdates": true, "sleepMinutes": 10,
                              "cloneFolder": NSHomeDirectory() + "/code", "useWorktrees": false, "captureSendTo": "active", "captureHotkey": true,
                              "autoMergeDefault": false, "securityScanOnPR": true])
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = d.bool(forKey: "showDockIcon")
        notify = d.bool(forKey: "notify")
        refreshSeconds = d.integer(forKey: "refreshSeconds")
        sidebarCollapsed = d.bool(forKey: "sidebarCollapsed")
        sleepMinutes = d.integer(forKey: "sleepMinutes")
        tabsOnSide = d.bool(forKey: "tabsOnSide")
        cloneFolder = d.string(forKey: "cloneFolder") ?? NSHomeDirectory() + "/code"
        useWorktrees = d.bool(forKey: "useWorktrees")
        captureSendTo = d.string(forKey: "captureSendTo") ?? "active"
        captureHotkey = d.bool(forKey: "captureHotkey")
        autoMergeDefault = d.bool(forKey: "autoMergeDefault")
        securityScanOnPR = d.bool(forKey: "securityScanOnPR")
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
