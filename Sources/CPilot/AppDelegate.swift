// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Owns the menu bar item (with its popover arrow), the Dock presence, and the Manager window.
/// The popover's views and the window are created on demand and destroyed on close, so a closed UI holds no view memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var managerWindow: NSWindow?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotMode.dir != nil { SnapshotMode.run(); return }
        if CommandLine.arguments.contains("--bench") { Bench.run(delegate: self) }
        NSSetUncaughtExceptionHandler { e in AppLog.info("UNCAUGHT \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(20).joined(separator: "\n"))") }
        Prefs.shared.applyTheme()
        Prefs.shared.applyDockIcon()
        NSApp.applicationIconImage = AppIcon.image(size: 512, padded: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("CPilot")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        model.onStatusChange = { [weak self] state in self?.statusItem.button?.image = StatusIcon.image(state) }

        Task { await model.refresh() }
        applyHotkey()
        ControlServer.shared.start()
        PRCenter.shared.startWatcher()
        StackCenter.shared.startWatcher()
        CIWatcher.shared.start()
        Updater.shared.confirmLaunch()                                   // tells a pending swap script "the new version started"
        Task { Updater.shared.autoCheckIfDue(enabled: Prefs.shared.autoCheckUpdates) }
        if model.needsSetup { showManager() }                            // first run: show the guided setup, not an empty window
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc func openSettings() { showManager(pane: .settings) }

    /// Control-Option-Command-C captures a region of the screen into the active session.
    func applyHotkey() {
        Hotkey.shared.register(Prefs.shared.captureHotkey) { CaptureCoordinator.shared.capture(window: false) }
    }

    @objc func newSession() { Nav.shared.showNewSession = true; showManager(pane: .sessions) }
    @objc func closeTab() {
        if Nav.shared.pane == .sessions, let id = Workspace.shared.selected, managerWindow?.isKeyWindow == true { Workspace.shared.closeTab(id) }
        else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func nextTab() { moveTab(1) }
    @objc func previousTab() { moveTab(-1) }
    @objc func captureRegion() { CaptureCoordinator.shared.capture(window: false) }
    @objc func captureWindow() { CaptureCoordinator.shared.capture(window: true) }
    @objc func captureSelection() { CaptureCoordinator.shared.addSelection(to: nil) }
    @objc func captureBrowser() { CaptureCoordinator.shared.addBrowserPage(to: nil) }
    @objc func captureClipboard() { CaptureCoordinator.shared.addClipboard(to: nil) }
    @objc func gotoTab(_ sender: NSMenuItem) {
        let ws = Workspace.shared
        if sender.tag < ws.tabs.count { ws.select(ws.tabs[sender.tag]) }
    }
    private func moveTab(_ d: Int) {
        let ws = Workspace.shared
        guard let cur = ws.selected, let i = ws.tabs.firstIndex(of: cur), !ws.tabs.isEmpty else { return }
        ws.select(ws.tabs[(i + d + ws.tabs.count) % ws.tabs.count])
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open CPilot", action: #selector(openManager), keyEquivalent: "").target = self
            let cap = NSMenuItem(title: "Capture", action: nil, keyEquivalent: ""); let sub = NSMenu()
            for (t, a) in [("Region", #selector(captureRegion)), ("Window", #selector(captureWindow)), ("Selected text", #selector(captureSelection)),
                           ("Front browser page", #selector(captureBrowser)), ("Clipboard", #selector(captureClipboard))] { sub.addItem(withTitle: t, action: a, keyEquivalent: "").target = self }
            cap.submenu = sub; m.addItem(cap)
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit CPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { togglePopover() }
    }
    @objc private func openManager() { showManager() }

    func closeManagerForBench() { managerWindow?.close() }
    func togglePopoverForBench() { togglePopover() }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        applyAppearance()
        let host = NSHostingController(rootView: PopoverView(openManager: { [weak self] p in self?.showManager(pane: p) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // release the popover's views while hidden
    }

    func showManager(pane: Pane? = nil) {
        if let pane { Nav.shared.pane = pane }
        popover.performClose(nil)
        if managerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 560)
            w.setFrameAutosaveName("CPilotManager")
            w.delegate = self
            w.contentView = NSHostingView(rootView: ManagerView())
            w.title = "CPilot"
            if !w.setFrameUsingName("CPilotManager") { w.center() }
            managerWindow = w
        }
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.setManagerVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === managerWindow else { return }
        model.setManagerVisible(false)
        managerWindow?.contentView = nil   // frees the SwiftUI tree
        managerWindow = nil
    }

    // Clicking the Dock icon opens the Manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { Workspace.shared.flushAll(); ControlServer.shared.stop() }

    // The app lives in the menu bar: closing the last window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
