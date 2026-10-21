// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ShellResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
    public var ok: Bool { status == 0 }
    public var lines: [String] { stdout.split(whereSeparator: \.isNewline).map(String.init) }
}

public enum ShellError: Error, LocalizedError {
    case toolNotFound(String)
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let t): return "\(t) was not found. Install it with Homebrew: brew install \(t)"
        case .failed(let c, let s, let e):
            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "\(c) exited with status \(s)" : msg
        case .timedOut(let c): return "\(c) timed out"
        }
    }
}

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Runs command line tools with a PATH that works for GUI apps (which do not inherit your shell PATH).
public enum Shell {
    public static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["NO_COLOR"] = "1"
        return env
    }

    public static func find(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchDirs {
            let path = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func makeProcess(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:]) throws -> Process {
        // Inside `Exec.with(environment)` every command runs on that server, over SSH.
        if let remote = Exec.environment {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SSH.executable)
            p.arguments = SSH.baseArgs(remote, acceptNewHostKeys: Exec.acceptNewHostKeys) + [remote.target, SSH.remoteCommand(tool, args, cwd: cwd?.path, env: env)]
            p.environment = SSH.environment(for: remote)
            return p
        }
        guard let path = find(tool) else { throw ShellError.toolNotFound(tool) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment.merging(env) { _, new in new }
        p.currentDirectoryURL = cwd
        return p
    }

    /// Run to completion and collect output. Does not throw on non-zero exit; check `ok`.
    @discardableResult
    public static func run(_ tool: String, _ args: [String], cwd: URL? = nil, input: Data? = nil, timeout: TimeInterval? = 60) async throws -> ShellResult {
        let process = try makeProcess(tool, args, cwd: cwd)
        let out = Buffer(), err = Buffer()
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }
        let command = ([tool] + args).joined(separator: " ")

        return try await withCheckedThrowingContinuation { cont in
            let timedOut = Buffer()
            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                if !timedOut.string.isEmpty { cont.resume(throwing: ShellError.timedOut(command)); return }
                cont.resume(returning: ShellResult(stdout: out.string, stderr: err.string, status: proc.terminationStatus))
            }
            do { try process.run() } catch { cont.resume(throwing: error); return }
            if let input { try? inPipe.fileHandleForWriting.write(contentsOf: input); try? inPipe.fileHandleForWriting.close() }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { timedOut.append(Data("1".utf8)); process.terminate() }
                }
            }
        }
    }

    /// Run and throw if the exit status is not zero. Returns trimmed stdout.
    @discardableResult
    public static func check(_ tool: String, _ args: [String], cwd: URL? = nil, input: Data? = nil, timeout: TimeInterval? = 60) async throws -> String {
        let r = try await run(tool, args, cwd: cwd, input: input, timeout: timeout)
        guard r.ok else { throw ShellError.failed(command: ([tool] + args).joined(separator: " "), status: r.status, stderr: r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r.stdout
    }

    /// Run a long task and report each output line (stdout and stderr) as it arrives.
    public static func stream(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = try makeProcess(tool, args, cwd: cwd, env: env)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        final class Carry: @unchecked Sendable { var s = "" }
        let carry = Carry()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            lock.lock(); defer { lock.unlock() }
            carry.s += String(decoding: d, as: UTF8.self)
            while let nl = carry.s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(carry.s[..<nl]); carry.s.removeSubrange(...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let rest = carry.s + String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); lock.unlock()
                for l in rest.split(whereSeparator: \.isNewline) { onLine(String(l)) }
                cont.resume(returning: proc.terminationStatus)
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
