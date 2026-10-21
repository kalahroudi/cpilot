// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RepoSetupPlan: Equatable, Sendable {
    public var owner: String
    public var name: String
    public var isPublic = true
    public var description = ""
    public var topics: [String] = []
    public var license: License = .apache2
    public var readme = true
    public var pages = true
    public var protectMain = true
    public var securityScan = true
    /// Names of workflow jobs that must pass before merging. Leave empty until a workflow exists, or merges would wait forever.
    public var requiredChecks: [String] = []
    /// Off by default: even the owner goes through a pull request. On lets the owner push straight to main in an emergency.
    public var ownerMayPushDirectly = false
    public var slug: String { "\(owner)/\(name)" }

    public enum License: String, CaseIterable, Sendable {
        case apache2 = "apache-2.0", mit = "mit", none
        public var label: String { switch self { case .apache2: "Apache 2.0"; case .mit: "MIT"; case .none: "None" } }
    }
    public init(owner: String, name: String) { self.owner = owner; self.name = name }
}

public enum RepoSetup {
    // MARK: Pure pieces (tested)

    /// The "Protect main" ruleset: changes go through a pull request, history stays linear, main cannot be force pushed or deleted.
    /// Zero required approvals, so a solo owner can merge their own work. The owner role can bypass the pull request rules only while merging a pull request, never by pushing straight to main, unless `ownerMayPushDirectly` is set.
    public static func rulesetJSON(requiredChecks: [String], ownerMayPushDirectly: Bool = false) -> String {
        var rules: [[String: Any]] = [
            ["type": "deletion"], ["type": "non_fast_forward"], ["type": "required_linear_history"],
            ["type": "pull_request", "parameters": ["required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
                                                     "require_code_owner_review": false, "require_last_push_approval": false,
                                                     "required_review_thread_resolution": false]],
        ]
        if !requiredChecks.isEmpty {
            rules.append(["type": "required_status_checks", "parameters": [
                "strict_required_status_checks_policy": false,
                "required_status_checks": requiredChecks.map { ["context": $0] },
            ]])
        }
        let body: [String: Any] = [
            "name": "Protect main", "target": "branch", "enforcement": "active",
            "conditions": ["ref_name": ["include": ["~DEFAULT_BRANCH"], "exclude": [String]()]],
            "bypass_actors": [["actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": ownerMayPushDirectly ? "always" : "pull_request"]],
            "rules": rules,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func readme(_ plan: RepoSetupPlan) -> String {
        var s = "# \(plan.name)\n\n"
        s += plan.description.isEmpty ? "A new project.\n" : plan.description + "\n"
        if plan.license != .none { s += "\n## License\n\n\(plan.license.label)\n" }
        return s
    }

    public static func landingPage(_ plan: RepoSetupPlan) -> String {
        let desc = plan.description.isEmpty ? "A new project." : plan.description
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(plan.name)</title>
        <style>
        :root{--bg:#f5f5f7;--fg:#1d1d1f;--mut:#6e6e73;--ac:#2563eb}
        @media(prefers-color-scheme:dark){:root{--bg:#1c1c1f;--fg:#f2f2f4;--mut:#9a9aa2;--ac:#60a5fa}}
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
        main{max-width:34rem;padding:2rem 16px}h1{margin:0 0 .25rem;font-size:2.4rem}p{color:var(--mut)}a{color:var(--ac)}
        </style></head><body><main>
        <h1>\(plan.name)</h1>
        <p>\(desc)</p>
        <p><a href="https://github.com/\(plan.slug)">View on GitHub</a></p>
        </main></body></html>
        """
    }

    public static let gitignore = ".DS_Store\n.build/\nnode_modules/\ndist/\n.env\n.securitycage/\n"

    /// A small workflow that runs the security scan on every pull request. It scans the code as data and never runs it.
    public static func securityWorkflow(action: String = "kalahroudi/securitycage@main") -> String {
        """
        name: Security scan
        on:
          pull_request:
        permissions:
          contents: read
          pull-requests: write
          security-events: write
        jobs:
          scan:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: \(action)
                with:
                  fail-on: high
        """
    }

    // MARK: Steps (run by the app, each reported to the log)

    public static func run(_ plan: RepoSetupPlan, folder: String, log: @escaping @Sendable (String) -> Void) async throws {
        let dir = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        func write(_ rel: String, _ text: String) throws {
            let u = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: u.path) { try text.write(to: u, atomically: true, encoding: .utf8) }
        }
        let account = await GitHub.account()
        guard account != nil else { throw ShellError.failed(command: "gh", status: 1, stderr: "Sign in to GitHub first: gh auth login") }

        if !(await Git.isRepo(folder)) { try await Shell.check("git", ["init", "-b", "main"], cwd: dir) }
        if plan.readme { try write("README.md", readme(plan)) }
        try write(".gitignore", gitignore)
        if plan.license != .none, !fm.fileExists(atPath: dir.appendingPathComponent("LICENSE").path),
           let body = try? await Shell.check("gh", ["api", "licenses/\(plan.license.rawValue)", "--jq", ".body"]) {
            let year = String(Calendar.current.component(.year, from: .now))
            try write("LICENSE", body.replacingOccurrences(of: "[yyyy]", with: year).replacingOccurrences(of: "[year]", with: year)
                        .replacingOccurrences(of: "[name of copyright owner]", with: plan.name + " contributors")
                        .replacingOccurrences(of: "[fullname]", with: plan.name + " contributors"))
        }
        if plan.pages { try write("docs/index.html", landingPage(plan)) }
        log("Wrote README, license and ignore file")

        _ = try? await Shell.run("git", ["add", "-A"], cwd: dir)
        _ = try? await Shell.run("git", ["commit", "-m", "Initial commit"], cwd: dir)

        let hasRemote = (try? await Shell.check("git", ["remote", "get-url", "origin"], cwd: dir)) != nil
        if !hasRemote {
            try await Shell.check("gh", ["repo", "create", plan.slug, plan.isPublic ? "--public" : "--private", "--source", ".", "--remote", "origin", "--push"],
                                  cwd: dir, timeout: 120)
            log("Created \(plan.slug) and pushed main")
        } else {
            try await Shell.check("git", ["push", "-u", "origin", "HEAD"], cwd: dir, timeout: 120)
            log("Pushed main to origin")
        }

        var edit = ["repo", "edit", plan.slug, "--delete-branch-on-merge", "--enable-auto-merge", "--enable-squash-merge"]
        if !plan.description.isEmpty { edit += ["--description", plan.description] }
        for t in plan.topics { edit += ["--add-topic", t] }
        if plan.pages { edit += ["--homepage", "https://\(plan.owner.lowercased()).github.io/\(plan.name)/"] }
        _ = try? await Shell.run("gh", edit, cwd: dir)
        log("Set description, topics and merge settings")

        if plan.pages {
            let r = try? await Shell.run("gh", ["api", "-X", "POST", "repos/\(plan.slug)/pages", "-f", "source[branch]=main", "-f", "source[path]=/docs"], cwd: dir)
            log(r?.ok == true ? "GitHub Pages enabled from /docs" : "GitHub Pages could not be enabled (a private repo may need a paid plan)")
        }

        if plan.protectMain {
            let file = fm.temporaryDirectory.appendingPathComponent("cpilot-ruleset-\(UUID().uuidString).json")
            try rulesetJSON(requiredChecks: plan.requiredChecks, ownerMayPushDirectly: plan.ownerMayPushDirectly).write(to: file, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: file) }
            let r = try? await Shell.run("gh", ["api", "-X", "POST", "repos/\(plan.slug)/rulesets", "--input", file.path], cwd: dir)
            if r?.ok == true { log("Ruleset \"Protect main\" applied") }
            else { log("Could not apply the ruleset: " + ((r?.stderr ?? "").isEmpty ? "private repos need a paid GitHub plan" : r!.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }

        if plan.securityScan {
            try write(".github/workflows/security.yml", securityWorkflow())
            _ = try? await Shell.run("git", ["checkout", "-b", "chore/security-scan"], cwd: dir)
            _ = try? await Shell.run("git", ["add", "-A"], cwd: dir)
            _ = try? await Shell.run("git", ["commit", "-m", "Run a security scan on every pull request"], cwd: dir)
            _ = try? await Shell.run("git", ["push", "-u", "origin", "chore/security-scan"], cwd: dir, timeout: 120)
            if let url = try? await GitHub.create(title: "Run a security scan on every pull request", body: "Adds a workflow that scans each pull request.", base: "main", draft: false, in: folder) {
                log("Opened \(url)")
            }
            _ = try? await Shell.run("git", ["checkout", "main"], cwd: dir)
        }
        log("Done")
    }
}
