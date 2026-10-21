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
        return "Couldn't \(action.lowercased()). Please try again; if it keeps happening, open Settings → About → Show log."
    }
}
