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
    /// When a chief pilot run ends, keep the lessons from its reviewers' reports and failures as a note every later session in the repository starts with.
    var learnLessons: Bool { didSet { d.set(learnLessons, forKey: "learnLessons") } }
    /// Look over finished sessions now and then and propose changes that keep a repository's notes true. See `Dream`.
    var dream: Bool { didSet { d.set(dream, forKey: "dream") } }
    /// Let a dream change notes CPilot wrote itself (lessons, earlier dreams, agents) without waiting. Notes you wrote always wait for you. Every change can be undone.
    var dreamAuto: Bool { didSet { d.set(dreamAuto, forKey: "dreamAuto") } }
    /// The model a dream uses. Empty means Sonnet.
    var dreamModel: String { didSet { d.set(dreamModel, forKey: "dreamModel") } }
    /// When Claude's usage limit is reached, the chief pilot and CPilot's own workers carry on by themselves once it resets. Work that starts by itself always waits for the reset.
    var resumeAfterLimit: Bool { didSet { d.set(resumeAfterLimit, forKey: "resumeAfterLimit") } }
    /// Which spec tasks get a tester first: "off", "risky" (security, money, deletion, migrations and the like) or "all". See `TestFirst`.
    var testFirst: String { didSet { d.set(testFirst, forKey: "testFirst") } }
    /// The model that writes a task's tests. Empty uses the default model, so a different one can be chosen than writes the code.
    var testerModel: String { didSet { d.set(testerModel, forKey: "testerModel") } }
    /// A second tester on another model writes its own tests from the spec, held back from the implementer; where the two read the spec differently, you are asked. Empty is off.
    var secondTesterModel: String { didSet { d.set(secondTesterModel, forKey: "secondTesterModel") } }
    /// Keep a share of the tester's tests from the implementer, run only by the gate.
    var hiddenTests: Bool { didSet { d.set(hiddenTests, forKey: "hiddenTests") } }
    /// Review each spec for gaps before any tests are written, and approve it by itself when the review finds nothing.
    var specReview: Bool { didSet { d.set(specReview, forKey: "specReview") } }
    var specAutoApprove: Bool { didSet { d.set(specAutoApprove, forKey: "specAutoApprove") } }
    /// The model that reviews a spec for gaps. Empty uses the reviewer model.
    var specReviewModel: String { didSet { d.set(specReviewModel, forKey: "specReviewModel") } }
    /// Most agents working at once before work that starts by itself (triggers, the chief pilot's tasks and reviewers) waits. 0 is no limit.
    /// Remove the checkouts and put away the sessions of work that is delivered (Settings, Cleanup).
    var cleanUp: Bool { didSet { d.set(cleanUp, forKey: "cleanUp") } }
    /// Days a put-away session is kept before it is deleted. 0 keeps them for ever.
    var keepArchivedDays: Int { didSet { d.set(keepArchivedDays, forKey: "keepArchivedDays") } }
    var maxAgents: Int { didSet { d.set(maxAgents, forKey: "maxAgents") } }
    /// Tokens at which Claude compacts a conversation; 0 leaves it to Claude Code. See `ClaudeRunner.Config.autocompactTokens`.
    var autocompactUnattended: Int { didSet { d.set(autocompactUnattended, forKey: "autocompactUnattended"); UsageLens.shared.noteSettings() } }
    /// Refuse a read of a file the conversation already holds, unchanged. See `ReadOnce`.
    var readOnce: Bool { didSet { d.set(readOnce, forKey: "readOnce") } }
    /// Refuse reads of keys, tokens and environment files. See `SensitiveGuard`.
    var blockSensitiveReads: Bool { didSet { d.set(blockSensitiveReads, forKey: "blockSensitiveReads") } }
    var autocompactYours: Int { didSet { d.set(autocompactYours, forKey: "autocompactYours"); UsageLens.shared.noteSettings() } }
    /// Dollars a day that work starting by itself may spend before it waits for tomorrow. 0 is no budget.
    var dailyBudget: Int { didSet { d.set(dailyBudget, forKey: "dailyBudget") } }
    /// What one spec task may use before it stops and asks you. 0 is off for each.
    var taskDollars: Int { didSet { d.set(taskDollars, forKey: "taskDollars") } }
    var taskTurns: Int { didSet { d.set(taskTurns, forKey: "taskTurns") } }
    var taskMinutes: Int { didSet { d.set(taskMinutes, forKey: "taskMinutes") } }
    var taskBudget: TaskBudget { TaskBudget(dollars: taskDollars, turns: taskTurns, minutes: taskMinutes) }
    /// Index finished messages and recall the best matches at the start of a new session.
    var recall: Bool { didSet { d.set(recall, forKey: "recall") } }
    /// Show a recap when you open a session you have been away from.
    var recapAuto: Bool { didSet { d.set(recapAuto, forKey: "recapAuto") } }
    /// Let Claude rewrite recaps in friendlier language (a small, cheap call).
    var recapWithClaude: Bool { didSet { d.set(recapWithClaude, forKey: "recapWithClaude") } }
    /// Let Claude suggest your next message from the agent's last one; Tab fills it in (a small, cheap call after each turn).
    var suggestPrompts: Bool { didSet { d.set(suggestPrompts, forKey: "suggestPrompts") } }
    /// How much the agent does by itself when turning an idea into a spec and a stack: "step", "plan" or "hands".
    /// Offers "Merge all as admin" on a stack whose pull requests GitHub's rules block.
    var adminMergeAll: Bool { didSet { d.set(adminMergeAll, forKey: "adminMergeAll") } }
    /// How long Merge all waits for a conflict to be resolved. 0 waits for as long as it takes.
    var conflictWaitMinutes: Int { didSet { d.set(conflictWaitMinutes, forKey: "conflictWaitMinutes") } }
    var autoResolveConflicts: Bool { didSet { d.set(autoResolveConflicts, forKey: "autoResolveConflicts") } }
    /// Stacks that change the same files are combined into one pull request by themselves.
    var autoCollapse: Bool { didSet { d.set(autoCollapse, forKey: "autoCollapse") } }
    var specAutonomy: String { didSet { d.set(specAutonomy, forKey: "specAutonomy") } }
    /// How much the chief pilot does without asking ("leads" or "asks"; see `ChiefPilot.Autonomy`).
    /// Phone access: a loopback web server published on your tailnet. Off until you turn it on.
    var remoteEnabled: Bool { didSet { d.set(remoteEnabled, forKey: "remoteEnabled") } }
    var chiefAutonomy: String { didSet { d.set(chiefAutonomy, forKey: "chiefAutonomy") } }
    /// The model reviewers the chief pilot starts use ("" is the default model, else an alias or a full model id).
    var reviewerModel: String { didSet { d.set(reviewerModel, forKey: "reviewerModel") } }
    var chiefMode: ChiefPilot.Autonomy { ChiefPilot.Autonomy(rawValue: chiefAutonomy) ?? .leads }
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
                              "autoMergeDefault": false, "recall": true, "learnLessons": true, "dream": true, "dreamAuto": true, "resumeAfterLimit": true, "testFirst": "off", "hiddenTests": true, "specReview": true, "specAutoApprove": true, "cleanUp": true, "keepArchivedDays": 30, "maxAgents": 4, "autocompactUnattended": 200_000, "autocompactYours": 0, "readOnce": true, "blockSensitiveReads": true, "taskDollars": 10, "taskTurns": 40, "taskMinutes": 60, "dailyBudget": 0, "specAutonomy": "step", "chiefAutonomy": "leads", "adminMergeAll": true, "autoResolveConflicts": true, "autoCollapse": true, "conflictWaitMinutes": 40, "recapAuto": true, "recapWithClaude": true, "suggestPrompts": true, "securityScanOnPR": true, "notifyChecks": true, "followSession": true, "autoArchiveSpecs": true])
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = d.bool(forKey: "showDockIcon")
        notify = d.bool(forKey: "notify")
        refreshSeconds = d.integer(forKey: "refreshSeconds")
        sidebarCollapsed = d.bool(forKey: "sidebarCollapsed")
        sleepMinutes = d.integer(forKey: "sleepMinutes")
        localModelURL = d.string(forKey: "localModelURL") ?? SecurityCage.defaultModelURL
        securityCagePath = d.string(forKey: "securityCagePath") ?? ""
        specAutonomy = d.string(forKey: "specAutonomy") ?? "step"
        chiefAutonomy = d.string(forKey: "chiefAutonomy") ?? "leads"
        reviewerModel = d.string(forKey: "reviewerModel") ?? ""
        remoteEnabled = d.bool(forKey: "remoteEnabled")
        adminMergeAll = d.bool(forKey: "adminMergeAll")
        autoResolveConflicts = d.bool(forKey: "autoResolveConflicts")
        autoCollapse = d.bool(forKey: "autoCollapse")
        conflictWaitMinutes = d.integer(forKey: "conflictWaitMinutes")
        recapAuto = d.bool(forKey: "recapAuto")
        learnLessons = d.bool(forKey: "learnLessons")
        dream = d.bool(forKey: "dream")
        resumeAfterLimit = d.bool(forKey: "resumeAfterLimit")
        dreamAuto = d.bool(forKey: "dreamAuto")
        dreamModel = d.string(forKey: "dreamModel") ?? ""
        testFirst = d.string(forKey: "testFirst") ?? "off"
        testerModel = d.string(forKey: "testerModel") ?? ""
        hiddenTests = d.bool(forKey: "hiddenTests")
        secondTesterModel = d.string(forKey: "secondTesterModel") ?? ""
        specReview = d.bool(forKey: "specReview")
        specAutoApprove = d.bool(forKey: "specAutoApprove")
        specReviewModel = d.string(forKey: "specReviewModel") ?? ""
        cleanUp = d.bool(forKey: "cleanUp")
        keepArchivedDays = d.integer(forKey: "keepArchivedDays")
        maxAgents = d.integer(forKey: "maxAgents")
        autocompactUnattended = d.integer(forKey: "autocompactUnattended")
        autocompactYours = d.integer(forKey: "autocompactYours")
        readOnce = d.bool(forKey: "readOnce")
        blockSensitiveReads = d.bool(forKey: "blockSensitiveReads")
        dailyBudget = d.integer(forKey: "dailyBudget")
        taskDollars = d.integer(forKey: "taskDollars")
        taskTurns = d.integer(forKey: "taskTurns")
        taskMinutes = d.integer(forKey: "taskMinutes")
        recapWithClaude = d.bool(forKey: "recapWithClaude")
        suggestPrompts = d.bool(forKey: "suggestPrompts")
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
