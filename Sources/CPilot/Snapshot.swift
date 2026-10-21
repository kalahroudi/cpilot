// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// `CPilot --snapshot <dir>` renders the app's screens to PNG files for the docs, then exits.
/// It uses made-up sample data, never the user's real data. Add a Shot per screen/theme you want in the README.
enum SnapshotMode {
    nonisolated(unsafe) static var dir: String?

    @MainActor static func run() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        Demo.install()
        Task { @MainActor in
            for shot in shots { await render(shot, to: dir) }
            NSApp.terminate(nil)
        }
    }

    struct Shot { let name: String; let dark: Bool; let size: CGSize; let make: @MainActor () -> AnyView }

    @MainActor static var shots: [Shot] {
        func manager(_ p: Pane, dark: Bool = false, agents: Bool = false) -> Shot {
            Shot(name: "manager-\(p.rawValue)\(agents ? "-agents" : "")\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 1000, height: 700)) {
                Nav.shared.pane = p
                return AnyView(ManagerView(agentsTab: agents))
            }
        }
        func side() -> Shot {
            Shot(name: "manager-sessions-side", dark: false, size: CGSize(width: 1000, height: 700)) {
                Nav.shared.pane = .sessions; Prefs.shared.tabsOnSide = true
                return AnyView(ManagerView())
            }
        }
        func pop(dark: Bool = false) -> Shot {
            Shot(name: "popover\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 800, height: 600)) { AnyView(PopoverShot()) }
        }
        return [pop(), pop(dark: true), manager(.sessions), manager(.sessions, dark: true), side(), manager(.pulls), manager(.pulls, dark: true), manager(.repo), manager(.remote),
                manager(.memory), manager(.settings), manager(.settings, agents: true), manager(.help)]
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        let host = NSHostingView(rootView: shot.make().frame(width: shot.size.width, height: shot.size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))   // off screen, but still laid out and drawn
        win.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.name + ".png")) }
        win.orderOut(nil)
    }
}

/// A menu bar with the popover hanging from the icon, on a soft backdrop. Used only for screenshots.
struct PopoverShot: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.71, blue: 0.78), Color(red: 0.29, green: 0.37, blue: 0.49)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").bold(); Text("File"); Text("Edit"); Text("View")
                    Spacer()
                    Image(nsImage: StatusIcon.image(.active)).renderingMode(.template).padding(.horizontal, 6).padding(.vertical, 2).background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    Text("Tue 20 Oct  9:41")
                }.font(.system(size: 13)).foregroundStyle(.primary).padding(.horizontal, 14).frame(height: 28).background(.regularMaterial)
                PopoverView(openManager: { _ in })
                    .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12).padding(.top, 8).padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
        }
    }
}

/// Made-up data that looks like a typical day.
@MainActor enum Demo {
    static func install() {
        let m = AppModel.shared
        m.demo = true
        m.setupState = SetupState(items: [])
        m.loadedOnce = true; m.updatedAt = .now
        UserDefaults.standard.set("/Users/demo/code/shop", forKey: "lastFolder")
        m.github = GitHub.Account(login: "octo", scopes: "repo, read:org")

        let ws = Workspace.shared
        var a = SessionMeta(title: "fix-flaky-login-test", cwd: "/Users/demo/code/shop", model: "opus", branch: "fix/login-flake")
        a.updatedAt = .now
        var b = SessionMeta(title: "api-pagination", cwd: "/Users/demo/code/shop", branch: "api-pagination"); b.updatedAt = .now.addingTimeInterval(-300)
        var c = SessionMeta(title: "docs-audit", cwd: "/Users/demo/code/docs", backend: .acp("demo")); c.updatedAt = .now.addingTimeInterval(-900)
        var d = SessionMeta(title: "release-notes", cwd: "/Users/demo/code/shop"); d.updatedAt = .now.addingTimeInterval(-86400)
        var e = SessionMeta(title: "Add regression test", cwd: "/Users/demo/code/shop", branch: "task-add-regression-test"); e.parentId = a.id; e.updatedAt = .now.addingTimeInterval(-60)
        a.recap = "**Latest ask:** The login test fails about one run in five on CI. Find out why and fix it.\n\n**So far:** found the race between the click and the redirect, changed the test to wait for the session response.\n\n**Waiting on you:** approval to edit src/api/session.ts."
        let build = EnvironmentConfig(id: "build", name: "build-server", routes: ["build.internal", "100.64.2.7"], folders: ["~/projects"], persistent: true, home: "/home/dev")
        let lab = EnvironmentConfig(id: "lab", name: "home-lab", routes: ["lab.local"], folders: ["~/work"], home: "/home/me")
        ws.environments = [build, lab]
        EnvironmentCenter.shared.status = ["build": .ok(EnvironmentReport(connected: true, error: nil, home: "/home/dev", tools: ["claude": "/home/dev/.local/bin/claude", "git": "/usr/bin/git"], gitHubSignedIn: true)), "lab": .failed("Could not reach the server. Check the address and that it is online.")]
        var f = SessionMeta(title: "migrate-db-schema", cwd: "/home/dev/projects/shop", branch: "migrate-schema"); f.environment = "build"; f.updatedAt = .now.addingTimeInterval(-120)
        ws.sessions = [a, b, c, d, e, f]
        ws.tabs = [a.id, e.id, f.id, b.id, c.id, d.id]; ws.selected = a.id
        ws.demoControllers([a, b, c, d, e, f])
        ws.controller(f.id)?.state = .reconnecting
        if let s = ws.controller(a.id) {
            s.loaded = true
            s.items = [
                ChatItem(kind: .user, text: "The login test fails about one run in five on CI. Find out why and fix it."),
                ChatItem(kind: .assistant, text: "I'll start by reading the test and the helper it waits on.", status: .done),
                ChatItem(kind: .tool, text: "", title: "Read", detail: "tests/login.spec.ts", status: .done),
                ChatItem(kind: .assistant, text: "The test clicks submit before the session cookie is set, so it **races with the redirect**. I'll wait for the response instead of a fixed delay:\n\n```ts\nawait Promise.all([\n  page.waitForResponse(r => r.url().includes('/session')),\n  page.click('#submit'),\n])\n```", status: .done),
                ChatItem(kind: .tool, text: "Updated tests/login.spec.ts", title: "Edit", detail: "tests/login.spec.ts", status: .done),
                ChatItem(id: "agent1", kind: .tool, text: "", title: "Agent", detail: "Check how other tests wait for responses", status: .running),
                ChatItem(kind: .tool, title: "Grep", detail: "waitForResponse", status: .done, parent: "agent1"),
                ChatItem(kind: .tool, title: "Read", detail: "tests/checkout.spec.ts", status: .done, parent: "agent1"),
                ChatItem(kind: .tool, title: "Read", detail: "tests/helpers.ts", status: .running, parent: "agent1"),
                ChatItem(id: "perm-demo", kind: .permission, text: "src/api/session.ts", title: "Edit", detail: "/Users/demo/code/shop/src/api/session.ts", status: .pending,
                         preview: EditPreview.encode(EditPreview.lines(tool: "Edit", inputJSON: #"{"file_path":"/x","old_string":"res.cookie('sid', id, { httpOnly: true })","new_string":"res.cookie('sid', id, { httpOnly: true, secure: true, sameSite: 'lax' })"}"#))),
            ]
            s.state = .waiting
            s.pending = []
            s.recapVisible = true
        }
        ws.controller(e.id)?.state = .running
        for (i, id) in [b.id, c.id].enumerated() { ws.controller(id)?.state = i == 0 ? .running : .idle }

        let pr = PRCenter.shared
        pr.repoDir = "/Users/demo/code/shop"
        let p1 = PullRequest(number: 218, title: "Fix flaky login test", state: "OPEN", isDraft: false, headRefName: "fix/login-flake", baseRefName: "main",
                             author: .init(login: "octo"), url: "https://github.com/octo/shop/pull/218", body: "The login test raced the redirect. It now waits for the session response instead of a fixed delay. Ran 20 times locally, 20 passes.",
                             additions: 5, deletions: 2, reviewDecision: nil, mergeable: "MERGEABLE")
        let p2 = PullRequest(number: 217, title: "Add cursor pagination", state: "OPEN", isDraft: false, headRefName: "api-pagination", baseRefName: "main", author: .init(login: "octo"),
                             url: "u", autoMergeRequest: .init(mergeMethod: "SQUASH"))
        pr.prs = [p1, p2]; pr.selected = 218; pr.detail = p1
        pr.checks = [.init(name: "build", state: "SUCCESS"), .init(name: "test", state: "SUCCESS")]
        pr.files = DiffParser.parse("""
        diff --git a/tests/login.spec.ts b/tests/login.spec.ts
        --- a/tests/login.spec.ts
        +++ b/tests/login.spec.ts
        @@ -12,5 +12,8 @@ test('logs in', async ({ page }) => {
           await page.fill('#email', 'a@b.co')
        -  await page.waitForTimeout(500)
        +  await Promise.all([
        +    page.waitForResponse(r => r.url().includes('/session')),
        +    page.click('#submit'),
        +  ])
        diff --git a/src/api/session.ts b/src/api/session.ts
        --- a/src/api/session.ts
        +++ b/src/api/session.ts
        @@ -40,3 +40,3 @@ export function login(res) {
        -  res.cookie('sid', id, { httpOnly: true })
        +  res.cookie('sid', id, { httpOnly: true, secure: true })
        """)
        pr.scan = SecurityResult(findings: [SecurityFinding(title: "Session cookie missing SameSite", confirmed: true, detail: "src/api/session.ts:41 reproduced in an isolated container")], report: "")

        ws.memory.save(scope: MemoryStore.globalScope, name: "Writing style", body: "Plain language. Short sentences.")
    }
}
