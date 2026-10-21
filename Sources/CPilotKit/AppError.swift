import Foundation
import os

/// Errors a view can show as-is: already written for people.
public struct UserFacingError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The technical record. Users never see this; support / agents read it from `AppLog.fileURL` or Console.app.
public enum AppLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")
    public static var fileURL: URL { AppPaths().root.appendingPathComponent("app.log") }

    public static func error(_ error: Error, context: String) {
        let detail = String(reflecting: error)   // type + payload, not just localizedDescription
        logger.error("\(context, privacy: .public): \(detail, privacy: .public)")
        append("ERROR \(context): \(detail)")
    }

    public static func info(_ line: String) { logger.info("\(line, privacy: .public)"); append("INFO \(line)") }

    private static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: fileURL) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: data) }
        else { try? data.write(to: fileURL) }
    }
}

/// Turns any thrown error into one short, actionable sentence. Never exposes paths, exit codes, stderr or type names.
public enum UserError {
    public static func message(for error: Error, action: String) -> String {
        if let e = error as? UserFacingError { return e.message }
        if let e = error as? ShellError, case .failed(_, _, let stderr) = e, let known = knownGitHubFailure(stderr, action: action) { return known }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut:
                return "Couldn't \(action.lowercased()): check your internet connection and try again."
            default: break
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains((error as NSError).code) {
            return "Couldn't \(action.lowercased()): the app doesn't have permission to access a file it needs."
        }
        return "Couldn't \(action.lowercased()). Please try again; if it keeps happening, use Details to copy or report it."
    }
}

extension UserError {
    /// GitHub refusals that are expected and have a clear meaning, so they get their own sentence instead of a generic one.
    static func knownGitHubFailure(_ stderr: String, action: String) -> String? {
        let s = stderr.lowercased()
        if s.contains("can not approve your own pull request") { return "GitHub doesn't let you approve your own pull request. Ask someone else to review it, or merge it yourself if the rules allow." }
        if s.contains("can not request changes on your own pull request") { return "GitHub doesn't let you request changes on your own pull request. Leave a comment instead." }
        if s.contains("auth login") || s.contains("not logged in") || s.contains("bad credentials") { return "Couldn't \(action.lowercased()): GitHub isn't signed in. Run `gh auth login` in Terminal and try again." }
        if s.contains("resource not accessible") || s.contains("must have admin rights") || s.contains("permission") && s.contains("denied") { return "Couldn't \(action.lowercased()): your GitHub account doesn't have permission to do that here." }
        if s.contains("not mergeable") || s.contains("merge conflict") { return "Couldn't \(action.lowercased()): the pull request has conflicts or unmet requirements. Open it on GitHub to see which." }
        return nil
    }
}

/// A failure the user can read, copy and, if they agree, report. The detail is redacted before it is shown or sent.
public struct ErrorReport: Identifiable, Sendable {
    public let id = UUID()
    public let action: String
    public let message: String
    public let detail: String

    public init(_ error: Error, action: String) {
        self.action = action
        self.message = UserError.message(for: error, action: action)
        self.detail = ErrorReport.redact(ErrorReport.describe(error))
        AppLog.error(error, context: action)
    }

    /// What the tool actually said (for example gh's stderr), then the type and payload.
    static func describe(_ error: Error) -> String {
        let said = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let raw = String(reflecting: error)
        return said == raw ? said : "\(said)\n\n\(raw)"
    }

    /// Removes the home folder, user and host names, emails, addresses, repository names, command arguments and anything shaped like a token.
    static func redact(_ text: String) -> String {
        var s = text
        // A reflected ShellError carries the whole command line, including titles, bodies and paths the user typed.
        s = s.replacingOccurrences(of: "command: \"([^\" ]+)[^\"]*\"", with: "command: \"$1 ‹args removed›\"", options: .regularExpression)
        for name in [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName] where name.count > 1 {
            s = s.replacingOccurrences(of: name, with: "‹user›", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let patterns = ["gh[pousr]_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}", "sk-[A-Za-z0-9_-]{20,}",
                        "(?i)(token|password|secret|authorization)([\"'=: ]+)[^\\s\"']+", "https?://[^/\\s:@]+:[^@\\s]+@",
                        "github\\.com[/:][^/\\s]+/[^/\\s]+", "--repo [^\\s\"']+", "\\\\?'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\\\?'",
                        "/(Users|home)/[^/\\s\"']+", "/var/folders/[^\\s\"']+", "/Volumes/[^/\\s\"']+",
                        "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "\\b\\d{1,3}(\\.\\d{1,3}){3}\\b",
                        "\\b[A-Za-z0-9-]+\\.(ts\\.net|local|lan|internal)\\b", "\\b[0-9a-fA-F:]{12,}\\b"]
        for p in patterns { s = s.replacingOccurrences(of: p, with: "‹redacted›", options: .regularExpression) }
        return s
    }

    public var issueTitle: String { "Error: couldn't \(action.lowercased())" }

    public func issueBody(version: String) -> String {
        ErrorReport.redact(body(version: version))
    }

    private func body(version: String) -> String {
        """
        **What I was doing:** \(action)

        **Message shown:** \(message)

        **Version:** \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

        <details><summary>Technical details</summary>

        ```
        \(detail.prefix(6000))
        ```

        </details>
        """
    }
}

public enum IssueReporter {
    public static let repo = "kalahroudi/cpilot"

    /// Files the issue with the user's own `gh`; returns its URL. Falls back to a prefilled browser page when `gh` can't.
    public static func submit(_ report: ErrorReport, version: String) async throws -> URL {
        let out = try await Shell.check("gh", ["issue", "create", "--repo", repo, "--title", report.issueTitle,
                                                "--body", report.issueBody(version: version), "--label", "bug"], timeout: 60)
        guard let u = out.split(whereSeparator: \.isNewline).last.flatMap({ URL(string: String($0)) }) else {
            throw UserFacingError("The issue was sent, but GitHub did not return its address.")
        }
        return u
    }

    public static func prefilled(_ report: ErrorReport, version: String) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [.init(name: "title", value: report.issueTitle), .init(name: "body", value: String(report.issueBody(version: version).prefix(6000)))]
        return c?.url
    }
}
