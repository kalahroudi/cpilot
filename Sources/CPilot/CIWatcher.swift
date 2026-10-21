// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Tells you when the checks on your own open pull requests finish.
/// Cost: one `gh pr list` per repository (repositories are deduplicated, sessions in the same repository share it). It looks every minute
/// while a check is running and every ten minutes otherwise; a repository `gh` cannot read is left alone for an hour.
@MainActor
final class CIWatcher {
    static let shared = CIWatcher()
    private var task: Task<Void, Never>?
    private var watches: [String: CIWatch] = [:]
    private var topLevels: [String: String?] = [:]
    private var retryAfter: [String: Date] = [:]

    func start() {
        task?.cancel(); task = nil
        guard Prefs.shared.notifyChecks else { watches = [:]; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let running = await self?.tick() ?? false
                try? await Task.sleep(for: .seconds(running ? 60 : 600))
            }
        }
    }

    /// Returns true while any check is still running.
    private func tick() async -> Bool {
        guard !AppModel.shared.demo else { return false }
        var running = false, done = Set<String>()
        for r in Project.shared.repos() {
            let environment = Workspace.shared.environment(r.environment)
            let key = await Exec.with(environment) { await repoKey(r) }
            guard let key, done.insert(key).inserted, (retryAfter[key] ?? .distantPast) <= .now else { continue }
            guard let prs = try? await Exec.with(environment, { try await GitHub.mineWithChecks(in: r.dir) }) else {
                retryAfter[key] = .now.addingTimeInterval(3600); continue
            }
            var watch = watches[key] ?? CIWatch()
            let first = watches[key] == nil
            let events = watch.observe(prs)
            watches[key] = watch
            if watch.hasPending { running = true }
            if first { continue }
            for e in events { await announce(e, in: key) }
        }
        watches = watches.filter { done.contains($0.key) }
        return running
    }

    /// One identity per repository, so two sessions in the same repository (or one in a subfolder) are read once.
    private func repoKey(_ r: PRCenter.Repo) async -> String? {
        let k = r.dir + "|" + (r.environment ?? "")
        if let known = topLevels[k] { return known }
        let top = (try? await Shell.check("git", ["rev-parse", "--show-toplevel"], cwd: URL(fileURLWithPath: r.dir)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = top.flatMap { $0.isEmpty ? nil : $0 + "|" + (r.environment ?? "") }
        topLevels[k] = key
        return key
    }

    /// A pull request CPilot is set to merge says "Merged" or "can't merge" by itself, so "passed" would only be a second notification.
    /// A failure is always told: auto-merge will not happen.
    private func isMergedByCPilot(_ n: Int, in repo: String) async -> Bool {
        let path = repo.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        for (k, dir) in PRCenter.shared.armed where k.hasSuffix("#\(n)") {
            if let armedKey = await repoKey(PRCenter.Repo(dir: dir, environment: nil)), armedKey.hasPrefix(path + "|") { return true }
        }
        let stack = StackCenter.shared
        if let r = stack.repo, stack.isArmed(r), stack.stacks.contains(where: { $0.bottomOpen?.pr == n }),
           await repoKey(r) == repo { return true }
        return false
    }

    private func announce(_ e: CIWatch.Event, in repo: String) async {
        switch e.verdict {
        case .passed:
            if await isMergedByCPilot(e.pr.number, in: repo) { return }
            AppModel.shared.notify("#\(e.pr.number) checks passed", body: e.pr.title)
        case .failed(let names): AppModel.shared.notify("#\(e.pr.number) checks failed", body: names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : ""))
        default: break
        }
    }
}
