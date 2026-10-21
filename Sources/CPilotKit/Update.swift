// SPDX-License-Identifier: Apache-2.0

import Foundation

// Self-update model. The approach follows the mlxplayer app:
//   1. Prefer the latest published GitHub release (a signed disk image, no Xcode needed).
//   2. Otherwise compare this build's commit with the head of the branch and build from source.
//   3. Verify, swap the app bundle after quitting, and roll back if the new one never reports in.

/// Which build is running. Written into Info.plist by scripts/bundle.sh.
public struct BuildInfo: Equatable, Sendable {
    public var commit: String?
    public var repo: String
    public var branch: String
    public var version: String

    public init(commit: String?, repo: String = "kalahroudi/cpilot", branch: String = "main", version: String = "0") {
        self.commit = commit; self.repo = repo; self.branch = branch; self.version = version
    }

    /// The running app's build info.
    public static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return BuildInfo(commit: info["CPilotCommit"] as? String, repo: info["CPilotRepo"] as? String ?? "kalahroudi/cpilot",
                         branch: info["CPilotBranch"] as? String ?? "main", version: info["CFBundleShortVersionString"] as? String ?? "0.0.0")
    }

    /// The commit without a "-dirty" marker (the build had uncommitted changes).
    public var cleanCommit: String? {
        guard let c = commit, c != "unknown", !c.isEmpty else { return nil }
        return c.hasSuffix("-dirty") ? String(c.dropLast(6)) : c
    }
    public var isDirty: Bool { commit?.hasSuffix("-dirty") == true }
    public var shortCommit: String { cleanCommit.map { String($0.prefix(7)) } ?? "dev" }
}

/// A published GitHub release with a prebuilt disk image.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var version: String
    public var notes: [String]
    public var dmgURL: URL
    public var dmgName: String
    public var checksumsURL: URL?
}

public struct UpdateInfo: Equatable, Sendable {
    public var sha: String
    public var aheadBy: Int
    public var summaries: [String]
    /// Set when the update is a prebuilt release instead of a build from source.
    public var release: ReleaseInfo?
    public var shortSha: String { String(sha.prefix(7)) }
    public var label: String { release?.tag ?? shortSha }

    public init(sha: String, aheadBy: Int, summaries: [String], release: ReleaseInfo? = nil) {
        self.sha = sha; self.aheadBy = aheadBy; self.summaries = summaries; self.release = release
    }
}

/// Dotted versions such as "0.2.0" or "v1.4.1-beta.2". A pre-release sorts before its final.
public enum Version {
    public static func parse(_ s: String) -> (numbers: [Int], pre: String?)? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        return (nums.compactMap { $0 }, parts.count > 1 ? String(parts[1]) : nil)
    }

    /// True when `a` is higher than `b`. Unparseable versions are never newer.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.numbers.count, y.numbers.count) {
            let l = i < x.numbers.count ? x.numbers[i] : 0, r = i < y.numbers.count ? y.numbers[i] : 0
            if l != r { return l > r }
        }
        switch (x.pre, y.pre) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (l?, r?): return l.compare(r, options: .numeric) == .orderedDescending
        }
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
    /// This build can't be compared with the branch (local build, or it has commits the branch doesn't).
    case notComparable(String)
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case network(String), rateLimited, badResponse, missingTool(String), notBundled, notWritable(String), buildFailed(String), verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't reach GitHub. \(m)"
        case .rateLimited: return "GitHub is limiting requests. Try again in a few minutes."
        case .badResponse: return "GitHub sent an answer that couldn't be read."
        case .missingTool(let t): return "\(t) is needed to build the update. Install the Xcode command line tools."
        case .notBundled: return "Updates work from the installed app, not from a development build."
        case .notWritable(let p): return "No permission to replace \(p). Move the app to a folder you own."
        case .buildFailed(let m): return "The build failed. \(m)"
        case .verifyFailed(let m): return "The new build didn't pass checks, so nothing was replaced. \(m)"
        }
    }
}

/// Asks GitHub whether a newer release exists, or whether the branch has commits this build lacks.
public struct UpdateChecker: Sendable {
    public var session: URLSession
    public var apiBase = "https://api.github.com"

    public init(session: URLSession = .shared) { self.session = session }

    /// - allowBranch: when no newer release exists, also offer a build of the newest commit on the branch.
    public func check(_ build: BuildInfo, allowBranch: Bool = true) async throws -> UpdateStatus {
        // A newer prebuilt release wins: it installs without Xcode tools.
        if let release = try await latestRelease(repo: build.repo), Version.isNewer(release.version, than: build.version) {
            return .available(UpdateInfo(sha: release.tag, aheadBy: 0, summaries: release.notes, release: release))
        }
        guard allowBranch else { return .upToDate }
        guard let current = build.cleanCommit else { return .notComparable("This build has no commit recorded.") }
        let head = try await headSHA(repo: build.repo, branch: build.branch)
        if head == current { return .upToDate }
        let (data, code) = try await get("/repos/\(build.repo)/compare/\(current)...\(head)")
        if code == 404 { return .notComparable("This build isn't on \(build.branch) yet.") }
        guard code == 200 else { throw UpdateError.badResponse }
        return try Self.decide(compareJSON: data, head: head)
    }

    public func latestRelease(repo: String) async throws -> ReleaseInfo? {
        let (data, code) = try await get("/repos/\(repo)/releases/latest")
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError.badResponse }
        return Self.parseRelease(data)
    }

    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true,
              let tag = obj["tag_name"] as? String else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func url(_ a: [String: Any]) -> URL? { (a["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dmgName = dmg["name"] as? String, let dmgURL = url(dmg) else { return nil }
        let sums = assets.first { ($0["name"] as? String)?.uppercased().hasPrefix("SHA256SUMS") == true }
        let notes = ((obj["body"] as? String) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*#\r")) }.filter { !$0.isEmpty }
        return ReleaseInfo(tag: tag, version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: Array(notes.prefix(8)),
                           dmgURL: dmgURL, dmgName: dmgName, checksumsURL: sums.flatMap(url))
    }

    /// Finds the hash for `file` in `shasum -a 256` output ("<hash>  <name>" per line).
    public static func checksum(in sums: String, for file: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == file else { continue }
            return String(parts[0]).lowercased()
        }
        return nil
    }

    func headSHA(repo: String, branch: String) async throws -> String {
        let (data, code) = try await get("/repos/\(repo)/commits/\(branch)")
        guard code == 200, let sha = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String else { throw UpdateError.badResponse }
        return sha
    }

    /// Pure, so tests can feed it saved responses.
    public static func decide(compareJSON data: Data, head: String) throws -> UpdateStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = obj["status"] as? String else { throw UpdateError.badResponse }
        switch status {
        case "identical", "behind": return .upToDate
        case "ahead":
            let commits = obj["commits"] as? [[String: Any]] ?? []
            let lines = commits.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }.map { String($0.split(separator: "\n").first ?? "") }
            return .available(UpdateInfo(sha: head, aheadBy: obj["ahead_by"] as? Int ?? 0, summaries: Array(lines.suffix(8))))
        default: return .notComparable("This build has changes that aren't on the branch.")
        }
    }

    private func get(_ path: String) async throws -> (Data, Int) {
        guard let url = URL(string: apiBase + path) else { throw UpdateError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("cpilot-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 || code == 429 { throw UpdateError.rateLimited }
            return (data, code)
        } catch let e as UpdateError { throw e } catch { throw UpdateError.network(error.localizedDescription) }
    }
}

/// The script that swaps the app bundle after the app quits, and puts the old one back if the new one
/// never reports in. It runs outside the app because an app can't replace itself while running.
public enum UpdateSwap {
    public static let script = """
    #!/bin/bash
    # usage: swap.sh PID NEW_APP DEST_APP BACKUP_APP OK_MARKER TIMEOUT_SECONDS [OPEN_COMMAND]
    PID="$1"; NEW="$2"; DEST="$3"; BAK="$4"; MARK="$5"; TIMEOUT="${6:-30}"; OPEN="${7:-open}"

    # 1. Wait for the old app to quit, then make sure it has.
    for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID"; sleep 0.5; fi

    # 2. Swap, keeping the old bundle until the new one proves itself.
    rm -rf "$BAK"
    if ! mv "$DEST" "$BAK"; then echo "Couldn't move the current app aside." > "$MARK.failed"; $OPEN "$DEST"; exit 1; fi
    if ! mv "$NEW" "$DEST"; then
      mv "$BAK" "$DEST"; echo "Couldn't put the new app in place." > "$MARK.failed"; $OPEN "$DEST"; exit 1
    fi
    rm -f "$MARK" "$MARK.failed"
    $OPEN "$DEST"

    # 3. The new app writes the marker once it is up. No marker: roll back.
    for i in $(seq 1 $((TIMEOUT * 2))); do
      if [ -f "$MARK" ]; then rm -rf "$BAK"; exit 0; fi
      sleep 0.5
    done
    pkill -f "$DEST/Contents/MacOS/" 2>/dev/null; sleep 1
    rm -rf "$DEST"; mv "$BAK" "$DEST"
    echo "The new version didn't start, so the previous one was restored." > "$MARK.failed"
    $OPEN "$DEST"
    exit 2
    """
}
