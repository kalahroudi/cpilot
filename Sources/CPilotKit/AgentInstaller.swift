// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

public enum AgentInstallError: LocalizedError, Equatable {
    case noDownload(String)
    case badDownload(Int)
    case checksum(expected: String, got: String)
    case unsupportedArchive(String)
    case unsafe(String)
    case extractFailed(String)
    case missingCommand(String)

    public var errorDescription: String? {
        switch self {
        case .noDownload(let n): "\(n) has no download for this Mac."
        case .badDownload(let c): "The download failed (HTTP \(c))."
        case .checksum: "The download does not match the checksum in the registry, so CPilot did not install it."
        case .unsupportedArchive(let f): "CPilot cannot unpack \(f)."
        case .unsafe(let p): "The download contains a path outside its own folder (\(p)), so CPilot did not install it."
        case .extractFailed(let m): "Unpacking the download failed. \(m)"
        case .missingCommand(let c): "The download does not contain \(c)."
        }
    }
}

/// Installs an agent that the registry ships as a native download: fetches it over HTTPS, checks the registry's checksum when it
/// gives one, unpacks it into CPilot's own folder (never anywhere else) and returns the config that runs it.
public enum AgentInstaller {
    public struct Installed: Equatable, Sendable {
        public var config: AcpAgentConfig
        /// True when the registry gave a checksum and the download matched it.
        public var verified: Bool
    }

    public typealias Download = @Sendable (_ from: URL, _ to: URL) async throws -> Void

    public static var root: URL { AppPaths().root.appendingPathComponent("agents") }

    public enum Kind: Equatable { case zip, tar }

    public static func kind(of url: URL) -> Kind? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".zip") { return .zip }
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tar.xz") || n.hasSuffix(".tar") { return .tar }
        return nil
    }

    public static func safeName(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || "._+-".contains($0) ? $0 : "_" }) }
    public static func folder(id: String, version: String, root: URL = AgentInstaller.root) -> URL {
        root.appendingPathComponent(safeName(id)).appendingPathComponent(safeName(version.isEmpty ? "current" : version))
    }

    /// The version a config was installed from, when it points into CPilot's agents folder.
    public static func installedVersion(of config: AcpAgentConfig, root: URL = AgentInstaller.root) -> String? {
        let base = root.standardizedFileURL.path + "/"
        let path = URL(fileURLWithPath: config.command).standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        let parts = path.dropFirst(base.count).split(separator: "/")
        return parts.count >= 3 && String(parts[0]) == safeName(config.id) ? String(parts[1]) : nil
    }

    /// Where a Mac-installed agent lives on a server: the same folder layout, under that server's ~/.cpilot.
    public static func serverFolder(id: String, version: String, home: String) -> String {
        "\(home)/.cpilot/agents/\(safeName(id))/\(safeName(version.isEmpty ? "current" : version))"
    }

    /// The config to run on `env`: an agent CPilot downloaded for this Mac points into this Mac's folders, so it is pointed at the server's copy instead.
    public static func onServer(_ config: AcpAgentConfig, home: String) -> AcpAgentConfig {
        let base = root.standardizedFileURL.path + "/"
        let path = URL(fileURLWithPath: config.command).standardizedFileURL.path
        guard path.hasPrefix(base), let v = installedVersion(of: config) else { return config }
        let rest = path.dropFirst(base.count).split(separator: "/").dropFirst(2).joined(separator: "/")
        var c = config
        c.command = serverFolder(id: config.id, version: v, home: home) + "/" + rest
        return c
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Where `cmd` is inside `folder`. A command that climbs out of the folder, or is absolute, is refused.
    public static func resolve(cmd: String, in folder: URL) throws -> URL {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard !cmd.hasPrefix("/") else { throw AgentInstallError.unsafe(cmd) }
        let target = URL(fileURLWithPath: base).appendingPathComponent(cmd).standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { throw AgentInstallError.unsafe(cmd) }
        return URL(fileURLWithPath: target)
    }

    /// Everything that was unpacked must stay inside the folder, links included.
    static func checkContained(_ folder: URL) throws {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            if real != base && !real.hasPrefix(base + "/") { throw AgentInstallError.unsafe(url.lastPathComponent) }
        }
    }

    public static let download: Download = { url, file in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60; cfg.timeoutIntervalForResource = 900
        let (tmp, resp) = try await URLSession(configuration: cfg).download(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AgentInstallError.badDownload(code) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    /// Downloads, checks and unpacks `agent`. Installing a version that is already there does not download again.
    public static func install(_ agent: RegistryAgent, root: URL = AgentInstaller.root, download: Download = AgentInstaller.download) async throws -> Installed {
        guard let b = agent.binary else { throw AgentInstallError.noDownload(agent.name) }
        guard let archiveKind = kind(of: b.archive) else { throw AgentInstallError.unsupportedArchive(b.archive.lastPathComponent) }
        let fm = FileManager.default
        let dest = folder(id: agent.id, version: agent.version, root: root)
        func config(_ exe: URL) -> AcpAgentConfig { AcpAgentConfig(id: agent.id, name: agent.name, command: exe.path, args: b.args, env: b.env) }

        if let exe = try? resolve(cmd: b.cmd, in: dest), fm.isExecutableFile(atPath: exe.path) { return Installed(config: config(exe), verified: b.sha256 != nil) }

        let work = root.appendingPathComponent(".install-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(archiveKind == .zip ? "download.zip" : "download.tar")
        try await download(b.archive, archive)

        var verified = false
        if let expected = b.sha256 {
            let got = try sha256(of: archive)
            guard got == expected.lowercased() else { throw AgentInstallError.checksum(expected: expected, got: got) }
            verified = true
        }

        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        do {
            switch archiveKind {
            case .zip: _ = try await Shell.check("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], timeout: 600)
            case .tar: _ = try await Shell.check("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path], timeout: 600)
            }
        } catch { throw AgentInstallError.extractFailed(error.localizedDescription) }
        try checkContained(unpacked)

        let exe = try resolve(cmd: b.cmd, in: unpacked)
        guard fm.fileExists(atPath: exe.path) else { throw AgentInstallError.missingCommand(b.cmd) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: unpacked, to: dest)
        // Older versions of this agent are no longer needed.
        for old in (try? fm.contentsOfDirectory(at: dest.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != dest.lastPathComponent { try? fm.removeItem(at: old) }
        return Installed(config: config(try resolve(cmd: b.cmd, in: dest)), verified: verified)
    }

    public static func remove(_ config: AcpAgentConfig, root: URL = AgentInstaller.root) {
        guard installedVersion(of: config, root: root) != nil else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(safeName(config.id)))
    }
}
