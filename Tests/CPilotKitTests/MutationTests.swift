// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class MutationTests: XCTestCase {
    func testConfigIsReadFromKeyValueLines() throws {
        let c = try XCTUnwrap(Mutation.parseConfig("# mutation\ncommand: npx stryker run --mutate {files}\nreport: reports/mutation/mutation.json\nthreshold: 80%\ntimeout: 600\n"))
        XCTAssertEqual(c, Mutation.Config(command: "npx stryker run --mutate {files}", report: "reports/mutation/mutation.json", threshold: 80, timeout: 600))
        let d = try XCTUnwrap(Mutation.parseConfig("command: make mutate"))
        XCTAssertEqual(d.threshold, Mutation.defaultThreshold); XCTAssertNil(d.report); XCTAssertEqual(d.timeout, 1800)
        XCTAssertNil(Mutation.parseConfig("")); XCTAssertNil(Mutation.parseConfig("threshold: 80")); XCTAssertNil(Mutation.parseConfig("command:"))
        XCTAssertEqual(Mutation.parseConfig("command: x\nthreshold: 900")?.threshold, 100)
    }

    func testFilesAreFilledInQuotedAndOnlyWhenThereAreAny() {
        let c = Mutation.Config(command: "tool --mutate {files}", report: nil, threshold: 70, timeout: 60)
        XCTAssertEqual(Mutation.command(c, files: ["src/a.ts", "src/it's.ts"]), "tool --mutate 'src/a.ts' 'src/it'\\''s.ts'")
        XCTAssertNil(Mutation.command(c, files: []))
        XCTAssertEqual(Mutation.command(Mutation.Config(command: "make mutate", report: nil, threshold: 70, timeout: 60), files: []), "make mutate")
    }

    func testOnlySourceFilesAreMutated() {
        let diff = """
        diff --git a/src/gateway.ts b/src/gateway.ts
        --- a/src/gateway.ts
        +++ b/src/gateway.ts
        +x
        diff --git a/tests/gateway.test.ts b/tests/gateway.test.ts
        +y
        diff --git a/README.md b/README.md
        +z
        diff --git a/old.ts b/old.ts
        deleted file mode 100644
        -gone
        diff --git a/package.json b/package.json
        +{}
        diff --git a/.cpilot/verify b/.cpilot/verify
        +cmd
        """
        XCTAssertEqual(Mutation.sourceFiles(diff: diff), ["src/gateway.ts"])
    }

    let report = """
    {"schemaVersion": "1", "thresholds": {"high": 80, "low": 60}, "files": {
      "src/gateway.ts": {"language": "typescript", "source": "", "mutants": [
        {"id": "1", "mutatorName": "ConditionalExpression", "replacement": "true", "location": {"start": {"line": 12, "column": 5}, "end": {"line": 12, "column": 20}}, "status": "Killed"},
        {"id": "2", "mutatorName": "EqualityOperator", "replacement": "a <= b", "location": {"start": {"line": 30, "column": 9}, "end": {"line": 30, "column": 14}}, "status": "Survived"},
        {"id": "3", "mutatorName": "StringLiteral", "replacement": "\\"\\"", "location": {"start": {"line": 41, "column": 3}, "end": {"line": 41, "column": 9}}, "status": "NoCoverage"},
        {"id": "4", "mutatorName": "BlockStatement", "location": {"start": {"line": 50, "column": 1}, "end": {"line": 52, "column": 2}}, "status": "Timeout"},
        {"id": "5", "mutatorName": "ArithmeticOperator", "location": {"start": {"line": 60, "column": 1}, "end": {"line": 60, "column": 4}}, "status": "CompileError"},
        {"id": "6", "mutatorName": "Ignored", "location": {"start": {"line": 70, "column": 1}, "end": {"line": 70, "column": 4}}, "status": "Ignored"}
      ]},
      "src/other.ts": {"language": "typescript", "source": "", "mutants": [
        {"id": "7", "mutatorName": "LogicalOperator", "location": {"start": {"line": 3, "column": 1}, "end": {"line": 3, "column": 4}}, "status": "Killed"}
      ]}
    }}
    """

    func testReportScoreCountsCaughtOverJudgedAndListsSurvivors() throws {
        let r = try XCTUnwrap(Mutation.parseReport(Data(report.utf8)))
        XCTAssertEqual(r.killed, 3); XCTAssertEqual(r.survived, 1); XCTAssertEqual(r.noCoverage, 1)      // compile errors and ignored mutants are not judged
        XCTAssertEqual(r.score, 60, accuracy: 0.001)
        XCTAssertEqual(r.survivors.map(\.line), [30, 41]); XCTAssertEqual(r.survivors[0].text, "src/gateway.ts:30: EqualityOperator (changed to `a <= b`) and no test failed")
        XCTAssertNil(Mutation.parseReport(Data("not json".utf8))); XCTAssertNil(Mutation.parseReport(Data("{}".utf8)))
        XCTAssertEqual(Mutation.parseReport(Data(#"{"files": {}}"#.utf8))?.score, 100)
    }

    func testScoreIsReadFromOutput() {
        XCTAssertEqual(Mutation.parseScore("All files | 82.50 |\nMutation score: 82.5%\n"), 82.5)
        XCTAssertEqual(Mutation.parseScore("Mutation score 40% after 10\n...\nFinal mutation score: 71 %"), 71)
        XCTAssertNil(Mutation.parseScore("done, 12 passed"))
    }

    func testJudgeUsesTheReportThenTheOutputThenTheExitCode() {
        let c = Mutation.Config(command: "m", report: "r.json", threshold: 70, timeout: 60)
        if case .strengthen(let s, let surv) = Mutation.judge(c, ok: true, output: "", report: Data(report.utf8)) { XCTAssertEqual(s, 60, accuracy: 0.001); XCTAssertEqual(surv.count, 2) } else { XCTFail("report below the bar") }
        XCTAssertEqual(Mutation.judge(Mutation.Config(command: "m", report: nil, threshold: 50, timeout: 60), ok: true, output: "", report: Data(report.utf8)), .pass(score: 60))
        XCTAssertEqual(Mutation.judge(c, ok: true, output: "Mutation score: 90%", report: nil), .pass(score: 90))
        XCTAssertEqual(Mutation.judge(c, ok: false, output: "Mutation score: 30%", report: nil), .strengthen(score: 30, survivors: []))
        XCTAssertEqual(Mutation.judge(c, ok: true, output: "fine", report: nil), .pass(score: nil))
        guard case .unmeasured = Mutation.judge(c, ok: false, output: "command not found", report: nil) else { return XCTFail("a tool that did not run measured nothing") }
    }

    func testStrengthenPromptListsTheSurvivorsAndTheWayOut() {
        let p = Mutation.strengthenPrompt(task: SpecTask(id: "T003", title: "Gateway", done: false), criteria: [Specs.Criterion(id: "R1", text: "Stays on origin.", checks: [])], score: 60, threshold: 70,
                                          survivors: [Mutation.Survivor(file: "src/g.ts", line: 30, mutator: "EqualityOperator", replacement: "a <= b")])
        for expected in ["60%", "70%", "src/g.ts:30: EqualityOperator", "R1: Stays on origin.", "kill surviving mutants", "DISPUTE: AMENDED", "Do not change the code"] { XCTAssertTrue(p.contains(expected), expected) }
        XCTAssertTrue(Mutation.strengthenPrompt(task: SpecTask(id: "T1", title: "x", done: false), criteria: [], score: 10, threshold: 70, survivors: []).contains("printed only the score"))
    }
}
