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
