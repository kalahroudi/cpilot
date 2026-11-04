// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class TaskSummaryTests: XCTestCase {
    private func diff(_ files: [(String, Int, Int)]) -> String {
        files.map { path, add, del in
            "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n"
                + (0..<del).map { "-old \($0)" }.joined(separator: "\n") + (del > 0 ? "\n" : "")
                + (0..<add).map { "+new \($0)" }.joined(separator: "\n") + (add > 0 ? "\n" : "")
        }.joined()
    }

    private func summarize(_ files: [(String, Int, Int)], touches: [String] = [], verified: [String] = ["swift test"], attempts: Int = 1) -> TaskSummary {
        TaskSummarizer.summarize(diff: diff(files), head: "abc", touches: touches, protected: ScopeGuard.defaultProtected, verified: verified, attempts: attempts)
    }

    func testASmallTestedChangeIsLowRisk() {
        let s = summarize([("Sources/A.swift", 10, 2), ("Tests/ATests.swift", 8, 0)])
        XCTAssertEqual(s.risk, .low)
        XCTAssertTrue(s.reasons.isEmpty)
        XCTAssertEqual(s.headline, "2 files, +18 −2")
        XCTAssertEqual(s.verified, ["swift test"])
    }

    func testCodeWithoutATestOrACheck() {
        let none = summarize([("Sources/A.swift", 5, 0)], verified: [])
        XCTAssertEqual(none.risk, .high, "no test (2) and nothing run (2)")
        let noTest = summarize([("Sources/A.swift", 5, 0)])
        XCTAssertEqual(noTest.risk, .medium)
        XCTAssertTrue(noTest.reasons[0].contains("no test"))
    }

    func testDependenciesAndSensitiveCodeAreCalledOut() {
        let s = summarize([("Package.swift", 2, 0), ("Sources/AuthToken.swift", 4, 0), ("Tests/T.swift", 1, 0)])
        XCTAssertEqual(s.risk, .high)
        XCTAssertTrue(s.reasons.contains { $0.contains("depends on") && $0.contains("Package.swift") })
        XCTAssertTrue(s.reasons.contains { $0.contains("access or secrets") })
    }

    func testProtectedFilesTheTaskNamesAreHighRisk() {
        let s = summarize([(".github/workflows/ci.yml", 3, 1), ("Tests/T.swift", 1, 0)], touches: [".github/"])
        XCTAssertEqual(s.risk, .high)
        XCTAssertTrue(s.reasons[0].contains("protected files"), "the most serious reason comes first")
    }

    func testSchemaChangesAreMedium() {
        XCTAssertEqual(summarize([("db/migrations/001_users.sql", 20, 0), ("Tests/T.swift", 1, 0)]).risk, .medium)
    }

    func testSizeCountsButLockFilesDoNot() {
        XCTAssertTrue(summarize([("Sources/Big.swift", 1200, 0), ("Tests/T.swift", 1, 0)]).reasons.contains { $0.contains("Large") })
        XCTAssertEqual(summarize([("Sources/A.swift", 5, 0), ("Tests/T.swift", 1, 0), ("Package.resolved", 3000, 0)]).risk, .low)
    }

    func testManyTriesAloneStayLowButAreListed() {
        let s = summarize([("Sources/A.swift", 5, 0), ("Tests/T.swift", 1, 0)], attempts: 6)
        XCTAssertEqual(s.risk, .low, "one point alone stays low")
        XCTAssertTrue(s.reasons.contains { $0.contains("6 tries") })
    }

    func testBiggestChangesComeFirst() {
        XCTAssertEqual(summarize([("a.md", 1, 0), ("b.md", 50, 10), ("c.md", 5, 5)]).biggest.map(\.path), ["b.md", "c.md", "a.md"])
    }

    func testASummaryIsKeptWithTheGateRecord() throws {
        var r = GateRecord(); r.summary = summarize([("Sources/A.swift", 5, 0)])
        XCTAssertEqual(try JSONDecoder().decode(GateRecord.self, from: JSONEncoder().encode(r)).summary, r.summary)
        let old = #"{"state":{"runs":1,"failures":[]},"answering":false,"updated":"2026-01-01T00:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertNil(try dec.decode(GateRecord.self, from: Data(old.utf8)).summary)
    }
}

final class SummaryMarkdownTests: XCTestCase {
    private func summary(head: String = "abcdef1234567") -> TaskSummary {
        let diff = "diff --git a/Sources/A.swift b/Sources/A.swift\n--- a/Sources/A.swift\n+++ b/Sources/A.swift\n@@ -1 +1 @@\n+one\n+two\n-old\n"
        return TaskSummarizer.summarize(diff: diff, head: head, touches: [], protected: ScopeGuard.defaultProtected, verified: ["swift test"], attempts: 2)
    }

    func testItNamesTheRiskTheReasonsAndWhatWasRun() {
        let m = summary().markdown()
        XCTAssertTrue(m.hasPrefix("<!-- cpilot-summary -->") && m.hasSuffix("<!-- /cpilot-summary -->"))
        XCTAssertTrue(m.contains("Medium risk"))
        XCTAssertTrue(m.contains("1 file, +2 −1"))
        XCTAssertTrue(m.contains("Changes code but no test"))
        XCTAssertTrue(m.contains("- `swift test` passed"))
        XCTAssertTrue(m.contains("`Sources/A.swift` (+2 −1)"))
        XCTAssertTrue(m.contains("try 2"))
    }

    func testItSaysSoWhenCommitsWereAddedAfterTheCheck() {
        XCTAssertFalse(summary().markdown(currentHead: "abcdef1234567").contains("out of date"))
        XCTAssertFalse(summary().markdown(currentHead: nil).contains("out of date"))
        let m = summary().markdown(currentHead: "999999999")
        XCTAssertTrue(m.contains("Checked at `abcdef1`") && m.contains("out of date"))
    }
}
