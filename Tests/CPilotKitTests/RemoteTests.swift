// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

/// A stand-in for `ssh`: runs the remote command on this machine, and refuses the host named "bad".
enum FakeSSH {
    static let path: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        # the last argument is the remote command, the one before it is the target
        for a; do prev="$last"; last="$a"; done
        if [ "$prev" = "bad" ]; then echo "Permission denied (publickey)." >&2; exit 255; fi
        exec sh -c "$last"
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }()
    static func use() { SSH.executable = path }
}

final class RemoteTests: XCTestCase {
    override func setUp() { FakeSSH.use() }

    func testQuotingAndCommandShape() {
        XCTAssertEqual(SSH.quote("it's"), "'it'\\''s'")
        let c = SSH.remoteCommand("claude", ["-p", "say 'hi'"], cwd: "/srv/my project", env: ["A": "1"])
        XCTAssertTrue(c.hasPrefix("bash -lc '"))
        XCTAssertTrue(c.contains("cd") && c.contains("my project") && c.contains("exec"))
    }

    func testCommandsRunOnTheEnvironmentWithSpacesAndQuotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("my dir \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = EnvironmentConfig(name: "t", routes: ["good"])
        let out = try await Exec.with(env) { try await Shell.check("sh", ["-c", "echo \"$PWD|$1\"", "x", "it's \"quoted\""], cwd: dir) }
        XCTAssertTrue(out.contains(dir.lastPathComponent)); XCTAssertTrue(out.contains("it's \"quoted\""))
        let none = try await Shell.check("echo", ["local"])
        XCTAssertEqual(none.trimmingCharacters(in: .whitespacesAndNewlines), "local")
    }

    func testProbeAndRouteFallback() async {
        let env = EnvironmentConfig(name: "t", routes: ["bad", "good"])
        let bad = await EnvironmentProbe.check(EnvironmentConfig(name: "x", routes: ["bad"]))
        XCTAssertFalse(bad.connected); XCTAssertTrue(bad.error?.contains("key") == true)
        let (connected, report) = await EnvironmentProbe.connect(env)
        XCTAssertTrue(report.connected); XCTAssertEqual(connected.active, 1); XCTAssertEqual(connected.target, "good")
        XCTAssertNotNil(report.home); XCTAssertTrue(report.has("git"))
    }

    func testConfiguredHostsAndStorage() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try "Host build-server\n  HostName x\nHost *\n  User y\nHost lab gpu !skip\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSH.configuredHosts(configPath: f.path), ["build-server", "lab", "gpu"])
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString).json")
        EnvironmentConfig.save([EnvironmentConfig(name: "a", routes: ["h"], folders: ["~/p"], persistent: true)], to: store)
        XCTAssertEqual(EnvironmentConfig.load(from: store).first?.folders, ["~/p"])
    }
}

/// The real helper, run by real Node through the fake ssh: start an agent, attach, detach, attach again, nothing lost.
final class DaemonTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        try XCTSkipIf(Shell.find("node") == nil, "node is not installed")
        FakeSSH.use()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cpilotd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CPILOTD_HOME", home.appendingPathComponent("sessions").path, 1)
        RemoteHost.scriptLocation = home.appendingPathComponent("cpilotd.mjs").path
    }
    override func tearDown() { unsetenv("CPILOTD_HOME"); RemoteHost.scriptLocation = "$HOME/.cpilot/cpilotd.mjs" }

    /// Runs `cpilotd attach`, writes `send`, waits for `expect` lines, then drops the connection.
    func attach(_ id: String, from: Int, send: [String], expect: Int) async throws -> [String] {
        let c = RemoteHost.command(["attach", id, "--from", String(from)])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Shell.find(c.tool) ?? "/bin/sh"); p.arguments = c.args
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o
        try p.run()
        for l in send { try i.fileHandleForWriting.write(contentsOf: Data((l + "\n").utf8)) }
        var got = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let d = o.fileHandleForReading.availableData
            if d.isEmpty { break }
            got += String(decoding: d, as: UTF8.self)
            if got.split(separator: "\n").count >= expect { break }
        }
        p.terminate()
        return got.split(separator: "\n").map(String.init)
    }

    func testInstallStartDetachReattachStop() async throws {
        let env = EnvironmentConfig(name: "t", routes: ["good"])
        try await Exec.with(env) {
            let before = await RemoteHost.isInstalled()
            XCTAssertFalse(before)
            try await RemoteHost.install()
            let after = await RemoteHost.isInstalled()
            XCTAssertTrue(after)

            // A stand-in agent: echoes each line it is given as JSON, and says hello first.
            let agent = #"echo '{"hello":1}'; while read l; do echo "{\"echo\":\"$l\"}"; done"#
            try await RemoteHost.start(id: "s1", cwd: home.path, command: "sh", args: ["-c", agent])
            var st = await RemoteHost.status(id: "s1")
            XCTAssertEqual(st?.running, true)

            let first = try await attach("s1", from: 0, send: ["one"], expect: 2)
            XCTAssertEqual(first, [#"{"hello":1}"#, #"{"echo":"one"}"#])

            // The connection is gone, the agent keeps going and answers someone else.
            let second = try await attach("s1", from: 2, send: ["two"], expect: 1)
            XCTAssertEqual(second, [#"{"echo":"two"}"#])
            // Reattaching from the start replays everything, in order.
            let replay = try await attach("s1", from: 0, send: [], expect: 3)
            XCTAssertEqual(replay, [#"{"hello":1}"#, #"{"echo":"one"}"#, #"{"echo":"two"}"#])

            st = await RemoteHost.status(id: "s1")
            XCTAssertEqual(st?.lines, 3)
            await RemoteHost.stop(id: "s1")
            for _ in 0..<40 { st = await RemoteHost.status(id: "s1"); if st?.running == false { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertEqual(st?.running, false)
            // After it ended, the output can still be replayed.
            let tail = try await attach("s1", from: 1, send: [], expect: 2)
            XCTAssertEqual(tail, [#"{"echo":"one"}"#, #"{"echo":"two"}"#])
        }
    }

    func testMissingCommandIsReported() async throws {
        let env = EnvironmentConfig(name: "t", routes: ["good"])
        try await Exec.with(env) {
            try await RemoteHost.install()
            do { try await RemoteHost.start(id: "s2", cwd: home.path, command: "definitely-not-a-real-command", args: []); XCTFail("should fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("not found")) }
        }
    }
}
