// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class AgentInstallerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-install-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// An archive holding `bin/agent`, a script that answers like a tiny program, as a zip or a tar.
    func makeArchive(zip: Bool, extra: (URL) throws -> Void = { _ in }) async throws -> URL {
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let exe = src.appendingPathComponent("bin/agent")
        try "#!/bin/sh\necho agent-ok \"$@\"\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try extra(src)
        let out = tmp.appendingPathComponent("archive-\(UUID().uuidString.prefix(6)).\(zip ? "zip" : "tar.gz")")
        if zip { _ = try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.path, out.path]) }
        else { _ = try await Shell.check("/usr/bin/tar", ["-czf", out.path, "-C", src.path, "."]) }
        return out
    }

    func agent(archive: String = "https://example.com/agent.tar.gz", cmd: String = "./bin/agent", sha: String? = nil, version: String = "1.0") -> RegistryAgent {
        RegistryAgent(id: "demo", name: "Demo", detail: "", version: version, config: nil, needsRuntime: nil,
                      binary: BinaryDistribution(archive: URL(string: archive)!, cmd: cmd, args: ["acp"], env: ["K": "V"], sha256: sha))
    }

    func fetch(_ file: URL, counter: Counter? = nil) -> AgentInstaller.Download {
        { _, dest in counter?.bump(); try? FileManager.default.removeItem(at: dest); try FileManager.default.copyItem(at: file, to: dest) }
    }

    final class Counter: @unchecked Sendable { private(set) var n = 0; func bump() { n += 1 } }

    // MARK: Registry

    func testTheRegistryGivesTheDownloadForThisPlatform() {
        let json = #"{"agents":[{"id":"g","name":"Goose","version":"1.5","distribution":{"binary":{"darwin-aarch64":{"archive":"https://x.test/arm.tar.gz","cmd":"./goose","args":["acp"],"sha256":"ABCD"},"darwin-x86_64":{"archive":"https://x.test/x86.zip","cmd":"./goose"},"linux-x86_64":{"archive":"https://x.test/l.tar.gz","cmd":"./goose"}}}}]}"#
        let arm = AcpRegistry.parse(Data(json.utf8), platform: "darwin-aarch64")[0]
        XCTAssertEqual(arm.binary?.archive.absoluteString, "https://x.test/arm.tar.gz")
        XCTAssertEqual(arm.binary?.args, ["acp"])
        XCTAssertEqual(arm.binary?.sha256, "abcd", "checksums are compared in lower case")
        XCTAssertEqual(arm.version, "1.5")
        XCTAssertEqual(AcpRegistry.parse(Data(json.utf8), platform: "darwin-x86_64")[0].binary?.archive.lastPathComponent, "x86.zip")
        XCTAssertNil(AcpRegistry.parse(Data(json.utf8), platform: "windows-x86_64")[0].binary, "no download for another platform")
    }

    func testOnlyHTTPSDownloadsAreAccepted() {
        let json = #"{"agents":[{"id":"g","name":"G","distribution":{"binary":{"darwin-aarch64":{"archive":"http://x.test/a.zip","cmd":"./g"}}}}]}"#
        XCTAssertNil(AcpRegistry.parse(Data(json.utf8), platform: "darwin-aarch64")[0].binary)
    }

    func testPackagesStillRunThroughTheirRuntime() {
        let json = #"{"agents":[{"id":"a","name":"A","distribution":{"npx":{"package":"a@1","args":["--acp"]}}}]}"#
        let a = AcpRegistry.parse(Data(json.utf8))[0]
        XCTAssertEqual(a.config?.command, "npx"); XCTAssertNil(a.binary)
    }

    // MARK: Install

    func testInstallsFromATarAndRunsTheAgent() async throws {
        let archive = try await makeArchive(zip: false)
        let root = tmp.appendingPathComponent("agents")
        let done = try await AgentInstaller.install(agent(), root: root, download: fetch(archive))
        XCTAssertFalse(done.verified, "the registry gave no checksum")
        XCTAssertEqual(done.config.args, ["acp"]); XCTAssertEqual(done.config.env, ["K": "V"])
        XCTAssertTrue(done.config.command.hasPrefix(root.path + "/demo/1.0/"))
        let out = try await Shell.check(done.config.command, ["acp"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "agent-ok acp")
        XCTAssertEqual(AgentInstaller.installedVersion(of: done.config, root: root), "1.0")
    }

    func testInstallsFromAZipWithTheTopFolderOfTheArchive() async throws {
        let archive = try await makeArchive(zip: true)
        let src = archive.deletingPathExtension()
        _ = src
        // `ditto --keepParent` puts everything under the folder's name; the registry's cmd names that path.
        let top = try await Shell.check("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n").first!.split(separator: "/").first!
        let a = agent(archive: "https://example.com/agent.zip", cmd: "./\(top)/bin/agent")
        let done = try await AgentInstaller.install(a, root: tmp.appendingPathComponent("agents"), download: fetch(archive))
        let out = try await Shell.check(done.config.command, [])
        XCTAssertTrue(out.contains("agent-ok"))
    }

    func testAMatchingChecksumIsVerifiedAndAWrongOneStopsTheInstall() async throws {
        let archive = try await makeArchive(zip: false)
        let good = try AgentInstaller.sha256(of: archive)
        let ok = try await AgentInstaller.install(agent(sha: good), root: tmp.appendingPathComponent("a"), download: fetch(archive))
        XCTAssertTrue(ok.verified)
        let root = tmp.appendingPathComponent("b")
        do {
            _ = try await AgentInstaller.install(agent(sha: String(repeating: "0", count: 64)), root: root, download: fetch(archive))
            XCTFail("a wrong checksum must stop the install")
        } catch let e as AgentInstallError {
            guard case .checksum(_, let got) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(got, good)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("demo").path), "nothing is left behind")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".install") }.isEmpty, "the work folder is cleaned up")
    }

    func testInstallingTheSameVersionAgainDoesNotDownloadAgain() async throws {
        let archive = try await makeArchive(zip: false)
        let root = tmp.appendingPathComponent("agents"), count = Counter()
        _ = try await AgentInstaller.install(agent(), root: root, download: fetch(archive, counter: count))
        _ = try await AgentInstaller.install(agent(), root: root, download: fetch(archive, counter: count))
        XCTAssertEqual(count.n, 1)
    }

    func testANewVersionReplacesTheOldOne() async throws {
        let archive = try await makeArchive(zip: false)
        let root = tmp.appendingPathComponent("agents")
        _ = try await AgentInstaller.install(agent(version: "1.0"), root: root, download: fetch(archive))
        let v2 = try await AgentInstaller.install(agent(version: "2.0"), root: root, download: fetch(archive))
        XCTAssertEqual(AgentInstaller.installedVersion(of: v2.config, root: root), "2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("demo").path), ["2.0"])
    }

    func testACommandThatIsNotInTheDownloadIsReported() async throws {
        let archive = try await makeArchive(zip: false)
        do { _ = try await AgentInstaller.install(agent(cmd: "./nope"), root: tmp.appendingPathComponent("agents"), download: fetch(archive)); XCTFail() }
        catch { XCTAssertEqual(error as? AgentInstallError, .missingCommand("./nope")) }
    }

    func testACommandThatClimbsOutOfTheFolderIsRefused() async throws {
        let archive = try await makeArchive(zip: false)
        for cmd in ["../../../bin/sh", "/bin/sh", "./bin/../../escape"] {
            do { _ = try await AgentInstaller.install(agent(cmd: cmd), root: tmp.appendingPathComponent("agents"), download: fetch(archive)); XCTFail(cmd) }
            catch { XCTAssertEqual(error as? AgentInstallError, .unsafe(cmd), cmd) }
        }
    }

    func testALinkThatPointsOutsideTheDownloadIsRefused() async throws {
        let archive = try await makeArchive(zip: false) { src in
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("bin/evil").path, withDestinationPath: "/etc/passwd")
        }
        do { _ = try await AgentInstaller.install(agent(), root: tmp.appendingPathComponent("agents"), download: fetch(archive)); XCTFail("link out of the folder") }
        catch { guard case AgentInstallError.unsafe = error else { return XCTFail("\(error)") } }
    }

    func testAnUnknownArchiveTypeIsReportedBeforeAnythingIsDownloaded() async {
        let count = Counter()
        do { _ = try await AgentInstaller.install(agent(archive: "https://example.com/agent.exe"), root: tmp, download: fetch(tmp, counter: count)); XCTFail() }
        catch { XCTAssertEqual(error as? AgentInstallError, .unsupportedArchive("agent.exe")) }
        XCTAssertEqual(count.n, 0)
    }

    func testRemoveDeletesOnlyWhatCPilotInstalled() async throws {
        let archive = try await makeArchive(zip: false)
        let root = tmp.appendingPathComponent("agents")
        let done = try await AgentInstaller.install(agent(), root: root, download: fetch(archive))
        let outside = tmp.appendingPathComponent("mine"); try "x".write(to: outside, atomically: true, encoding: .utf8)
        AgentInstaller.remove(AcpAgentConfig(id: "demo", name: "Demo", command: outside.path), root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        AgentInstaller.remove(done.config, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("demo").path))
    }

    func testArchiveKinds() {
        for (n, k) in [("a.zip", AgentInstaller.Kind.zip), ("a.tar.gz", .tar), ("a.tgz", .tar), ("a.tar.bz2", .tar), ("A.TAR.GZ", .tar)] {
            XCTAssertEqual(AgentInstaller.kind(of: URL(string: "https://x.test/\(n)")!), k, n)
        }
        XCTAssertNil(AgentInstaller.kind(of: URL(string: "https://x.test/a.exe")!))
    }
}

/// Installs a real agent from the live registry and speaks ACP to it. Opt in with CPILOT_AGENT_LIVE=<registry id> (default antigravity-acp).
final class LiveAgentInstallTests: XCTestCase {
    func testRealAgentInstallsAndAnswersTheHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CPILOT_AGENT_LIVE"] != nil, "live agent install")
        let id = env["CPILOT_AGENT_LIVE"] == "1" ? "antigravity-acp" : env["CPILOT_AGENT_LIVE"]!
        let registry = await AcpRegistry.load()
        let agent = try XCTUnwrap(registry.first { $0.id == id }, "\(id) is not in the registry")
        try XCTSkipUnless(agent.binary != nil, "\(id) runs through npx or uvx, not a native download")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-agents-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let done = try await AgentInstaller.install(agent, root: root)
        FileHandle.standardError.write(Data("[live] installed \(done.config.command) verified=\(done.verified)\n".utf8))
        let client = AcpClient(config: done.config, cwd: FileManager.default.temporaryDirectory) { _ in }
        try await client.start()
        XCTAssertTrue(client.isRunning, "the downloaded agent starts and answers initialize")
        // An agent that wants a sign-in is signed in by `newSession` (a browser opens), which a test cannot do; it lists its methods instead.
        if client.authMethods.isEmpty { let session = try await client.newSession(); XCTAssertFalse(session.isEmpty) }
        else { FileHandle.standardError.write(Data("[live] sign-in methods: \(client.authMethods.map(\.name))\n".utf8)) }
    }
}

final class AgentCheckExplainTests: XCTestCase {
    func testPageSizeMismatchIsExplainedWithTheFix() {
        let log = "F1022 23:58:04.916375   20460 page-size.cc:19] Check failed: sysconf(_SC_PAGE_SIZE) == kPageSize (16384 vs. 4096) Compile-time page size does not match runtime page size\n*** Check failure stack trace: ***\n[tailscale-ssh: process died: signal: aborted]"
        let env = EnvironmentConfig(name: "node-1", routes: ["moram@node-1"])
        let why = AgentCheck.explain(log, agent: "Google Antigravity", on: env)
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("built for 4 KB") && why!.contains("node-1 runs 16 KB") && why!.contains("kernel=kernel8.img"))
        XCTAssertNil(AgentCheck.explain("something else broke", agent: "A", on: nil))
    }
}
