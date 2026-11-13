// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ReadReportTests: XCTestCase {
    private func bash(_ c: String) -> (path: String, range: String?)? { ReadTarget.extract(tool: "Bash", input: ["command": c]) }

    func testReadsAreFoundFromTheCallsOwnArguments() {
        XCTAssertEqual(ReadTarget.extract(tool: "Read", input: ["file_path": "/r/a.swift"])?.path, "/r/a.swift")
        XCTAssertEqual(ReadTarget.extract(tool: "Read", input: ["file_path": "/r/a.swift", "offset": 10, "limit": 50])?.range, "10+50")
        XCTAssertEqual(bash("sed -n '10,60p' Sources/A.swift")?.path, "Sources/A.swift")
        XCTAssertEqual(bash("sed -n '10,60p' Sources/A.swift")?.range, "10-60")
        XCTAssertEqual(bash("cd /r && sed -n 1,40p \"My File.swift\"")?.path, "My File.swift")
        XCTAssertEqual(bash("cat README.md | head -5")?.path, "README.md")
        XCTAssertEqual(bash("cd /r && tail -n 40 build.log")?.path, "build.log")
    }

    func testAnythingThatIsNotAPlainReadIsNotGuessedAt() {
        XCTAssertNil(bash("swift test --filter X"))
        XCTAssertNil(bash("git diff --stat"))
        XCTAssertNil(bash("grep -n foo Sources/A.swift"))
        XCTAssertNil(bash("echo $HOME > out.txt"))
        // The output of the second command is most of what came back, so it is not a read of the first file.
        XCTAssertNil(bash("cat Package.swift && swift test"))
        XCTAssertNil(bash("cd /r && cat a.txt; ls"))
        XCTAssertNil(bash("cat a.txt | python3 -"))
        XCTAssertNil(bash("cat a.txt > b.txt"))
        XCTAssertNil(ReadTarget.extract(tool: "Edit", input: ["file_path": "/r/a"]))
    }

    func testSecretsAreSensitiveButExamplesPublicKeysAndSourceAreNot() {
        for p in [".env", "/r/.env.local", "~/.ssh/id_ed25519", "/r/certs/server.pem", "/home/u/.npmrc", "/home/u/.aws/credentials", "/r/secrets.json"] { XCTAssertTrue(SensitivePaths.isSensitive(p), p) }
        for p in [".env.example", "/r/.env.sample", "~/.ssh/id_ed25519.pub", "~/.ssh/config", "internal/approvalsecret/approvalsecret.go", "/r/README.md", "/r/Sources/Keychain.swift"] { XCTAssertFalse(SensitivePaths.isSensitive(p), p) }
    }

    func testRepeatsOfTheSameFileAndRangeAreCountedAndDifferentRangesAreNot() {
        func t(_ id: String, _ path: String, _ range: String?, _ chars: Int) -> ToolEvent { ToolEvent(useId: id, session: "S", name: "Read", ts: .now, resultChars: chars, target: path, range: range) }
        let r = ReadReport([t("1", "a", "1-50", 1000), t("2", "a", "51-100", 1000), t("3", "a", "1-50", 1000), t("4", "b", nil, 400), t("5", "b", nil, 400), t("6", ".env", nil, 10),
                            ToolEvent(useId: "7", session: "S", name: "Bash", ts: .now, resultChars: 999)])
        XCTAssertEqual(r.totalReads, 6)
        XCTAssertEqual(r.repeatReads, 2)
        XCTAssertEqual(r.repeatChars, 1400)
        XCTAssertEqual(r.files.first?.path, "a")
        XCTAssertEqual(r.sensitive, [".env"])
    }

    func testTheLedgerKeepsWhichFileWasReadAndFillsItInForAnOlderLedger() throws {
        let line = "{\"type\":\"assistant\",\"sessionId\":\"S1\",\"timestamp\":\"2026-11-01T10:00:00.000Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet-5-5\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{\"file_path\":\"/r/a.swift\"}}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n{\"type\":\"user\",\"sessionId\":\"S1\",\"timestamp\":\"2026-11-01T10:00:01.000Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"hello\"}]}}\n"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try line.write(to: dir.appendingPathComponent("S1.jsonl"), atomically: true, encoding: .utf8)
        let store = UsageStore(path: dir.appendingPathComponent("usage.db"))
        store.sync(root: dir)
        let t = store.tools(session: "S1")
        XCTAssertEqual(t.first?.target, "/r/a.swift")
        XCTAssertEqual(t.first?.resultChars, 5)
    }
}
