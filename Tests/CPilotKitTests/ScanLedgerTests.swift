// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ScanLedgerTests: XCTestCase {
    private func ledger() -> ScanLedger { ScanLedger(path: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(UUID().uuidString).db")) }

    func testGeneratedVendoredAndBinaryFilesAreOutOfScope() {
        for p in ["src/auth/login.ts", "Sources/App/Main.swift", "deploy/Dockerfile", "config/app.yaml"] { XCTAssertTrue(ScanScope.included(p), p) }
        for p in ["node_modules/x/index.js", "web/dist/app.min.js", "pnpm-lock.yaml", "assets/logo.png", "build/out.o", "api/schema.pb.go", "vendor/lib/a.go", "Package.resolved"] { XCTAssertFalse(ScanScope.included(p), p) }
    }

    func testTheRiskiestFilesComeFirstAndTestsAndDocsLast() {
        let o = RiskRank.ordered(["README.md", "src/util/strings.ts", "tests/auth.test.ts", "src/auth/session-token.ts", "src/payments/webhook.ts", "src/db/sql-query.ts"])
        XCTAssertEqual(o.first, "src/auth/session-token.ts")
        XCTAssertLessThan(o.firstIndex(of: "src/payments/webhook.ts")!, o.firstIndex(of: "src/util/strings.ts")!)
        XCTAssertGreaterThan(o.firstIndex(of: "tests/auth.test.ts")!, o.firstIndex(of: "src/db/sql-query.ts")!)
    }

    func testOnlyChangedAndNewFilesAreScannedAgain() {
        let l = ledger()
        let files = ["src/auth.ts": "h1", "src/util.ts": "h2", "src/api.ts": "h3", "dist/bundle.js": "h9"]
        var p = l.plan(repo: "/r", files: files, prompt: "sec-v1", model: "m")
        XCTAssertEqual(Set(p.todo), ["src/auth.ts", "src/util.ts", "src/api.ts"])
        XCTAssertEqual(p.skipped, 1)
        for f in p.todo { l.record(.init(repo: "/r", path: f, hash: files[f]!, prompt: "sec-v1", model: "m", findings: f == "src/auth.ts" ? 2 : 0)) }
        p = l.plan(repo: "/r", files: files, prompt: "sec-v1", model: "m")
        XCTAssertTrue(p.todo.isEmpty)
        XCTAssertEqual(p.reusedFindings, 2)
        // One file changes and one is added.
        var next = files; next["src/api.ts"] = "h3b"; next["src/new.ts"] = "h4"
        p = l.plan(repo: "/r", files: next, prompt: "sec-v1", model: "m")
        XCTAssertEqual(Set(p.todo), ["src/api.ts", "src/new.ts"])
        XCTAssertEqual(Set(p.reused), ["src/auth.ts", "src/util.ts"])
    }

    func testANewPromptVersionOrAnotherModelOrRepoStartsAfresh() {
        let l = ledger()
        l.record(.init(repo: "/r", path: "a.ts", hash: "h", prompt: "v1", model: "m", findings: 1))
        XCTAssertTrue(l.plan(repo: "/r", files: ["a.ts": "h"], prompt: "v2", model: "m").reused.isEmpty)
        XCTAssertTrue(l.plan(repo: "/r", files: ["a.ts": "h"], prompt: "v1", model: "other").reused.isEmpty)
        XCTAssertTrue(l.plan(repo: "/elsewhere", files: ["a.ts": "h"], prompt: "v1", model: "m").reused.isEmpty)
        XCTAssertEqual(l.plan(repo: "/r", files: ["a.ts": "h"], prompt: "v1", model: "m").reused, ["a.ts"])
    }

    func testGitsContentIdsAreReadFromLsTree() {
        let t = "100644 blob aaa111\tsrc/a.ts\n100755 blob bbb222\tscripts/with space.sh\n160000 commit ccc333\tsub\n"
        XCTAssertEqual(GitBlobs.parse(t), ["src/a.ts": "aaa111", "scripts/with space.sh": "bbb222"])
    }
}
