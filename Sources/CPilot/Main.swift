// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Plain AppKit startup. There is deliberately no SwiftUI `App`/`Settings` scene: that adds an empty
/// "Settings" window behind Cmd-, and the real settings live in the Manager window.
@main
enum CPilotMain {
    static let delegate = MainActor.assumeIsolated { AppDelegate() }

    static func main() {
        let args = CommandLine.arguments
        // Command line helpers used by the build scripts and the updater. They must run before any app state exists.
        // SSH runs this to get a password: print it from the Keychain and leave. Only for password prompts.
        if args.contains("--askpass") {
            let prompt = args.last ?? ""
            if prompt.lowercased().contains("password"), let id = ProcessInfo.processInfo.environment["CPILOT_ASKPASS_ID"], let pw = SSHPassword.get(id) { print(pw); exit(0) }
            exit(1)
        }
        if args.contains("--self-test") { print("ok \(BuildInfo.current.commit ?? "dev")"); exit(0) }
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            do { try AppIcon.writeIconset(to: args[i + 1]); exit(0) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { SnapshotMode.dir = args[i + 1] }

        // Only one copy may run: two would poll the same resources and fight over the menu bar item.
        // Leave before any app state exists, and ask the running copy to show its window.
        if SnapshotMode.dir == nil, let other = Self.otherRunningInstance() {
            if let url = other.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) } else { other.activate() }
            Thread.sleep(forTimeInterval: 0.3)
            exit(0)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.delegate = delegate
            app.mainMenu = makeMainMenu()
            app.run()
        }
    }

    /// App, Edit and Window menus, so Cmd-, opens the real Settings pane and copy/paste/Cmd-W work in text fields and the Manager.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = target
            return i
        }
        add("CPilot", [
            item("About CPilot", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.openSettings), ",", target: delegate),
            .separator(),
            item("Hide CPilot", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit CPilot", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let capture: [NSMenuItem] = [
            item("Capture Region", #selector(AppDelegate.captureRegion), "c", [.control, .option, .command], target: delegate),
            item("Capture Window", #selector(AppDelegate.captureWindow), "", target: delegate),
            item("Add Selected Text", #selector(AppDelegate.captureSelection), "", target: delegate),
            item("Add Front Browser Page", #selector(AppDelegate.captureBrowser), "", target: delegate),
            item("Add Clipboard", #selector(AppDelegate.captureClipboard), "", target: delegate),
        ]
        add("Session", [
            item("New Session…", #selector(AppDelegate.newSession), "n", target: delegate),
            item("Quick Session", #selector(AppDelegate.quickSession), "n", [.command, .option], target: delegate),
            item("Close Tab", #selector(AppDelegate.closeTab), "w", target: delegate),
            item("Next Tab", #selector(AppDelegate.nextTab), "]", [.command, .shift], target: delegate),
            item("Previous Tab", #selector(AppDelegate.previousTab), "[", [.command, .shift], target: delegate),
            .separator(),
        ] + (1...9).map { n in
            let i = item("Tab \(n)", #selector(AppDelegate.gotoTab(_:)), String(n), target: delegate); i.tag = n - 1; return i
        } + [.separator()] + capture)
        add("Go", [
            item("Back", #selector(AppDelegate.goBack), "[", target: delegate),
            item("Forward", #selector(AppDelegate.goForward), "]", target: delegate),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    /// Another live copy of this app. Waits a moment, since an update relaunch starts the new copy as the old one exits.
    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }   // a bare `swift run` binary has no identity
        for attempt in 0..<10 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            guard let first = others.first else { return nil }
            if attempt == 9 { return first }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }
}
