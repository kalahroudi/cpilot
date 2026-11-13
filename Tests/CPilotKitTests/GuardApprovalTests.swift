// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class GuardApprovalTests: XCTestCase {
    private let pnpm = ProjectScripts.Found(runner: "pnpm", scripts: ["build", "guard:approve", "test", "approve-release"])

    func testTheGuardApprovalIsPickedOverOtherApprovals() {
        let r = GuardApproval.approveScript([pnpm])
        XCTAssertEqual(r?.script, "guard:approve")
        XCTAssertTrue(GuardApproval.invocation(pnpm, "guard:approve").args == ["run", "guard:approve"])
    }

    func testAnyApprovalIsUsedWhenThereIsNoGuardOneAndNoneWhenThereIsNoApproval() {
        XCTAssertEqual(GuardApproval.approveScript([.init(runner: "npm", scripts: ["approve-release"])])?.script, "approve-release")
        XCTAssertNil(GuardApproval.approveScript([.init(runner: "npm", scripts: ["build", "test"])]))
        XCTAssertEqual(GuardApproval.invocation(.init(runner: "make", scripts: []), "approve").args, ["approve"])
    }

    func testOnlyTheLockFileTheApprovalWritesIsStaged() {
        let s = GitStatusSummary(staged: ["src/a.ts"], unstaged: ["guard.lock.json", "src/b.ts"], untracked: ["packages/x/guard.lock.json", "notes.txt", "package-lock.json"])
        XCTAssertEqual(GuardApproval.lockFilesToStage(s), ["guard.lock.json", "packages/x/guard.lock.json"])
    }

    func testAWorktreeWaitsOnlyWithStagedChangesAndAnApprovalScript() {
        let staged = GitStatusSummary(staged: ["a"], unstaged: [], untracked: [])
        XCTAssertTrue(GuardApproval.waiting(status: staged, scripts: [pnpm]))
        XCTAssertFalse(GuardApproval.waiting(status: GitStatusSummary(staged: [], unstaged: ["a"], untracked: []), scripts: [pnpm]))
        XCTAssertFalse(GuardApproval.waiting(status: staged, scripts: [.init(runner: "pnpm", scripts: ["test"])]))
    }

    func testTheCommitMessageStartsWithTheTask() {
        XCTAssertEqual(GuardApproval.suggestedMessage(taskId: "T009", title: " Cap signups "), "T009: Cap signups")
        XCTAssertEqual(GuardApproval.suggestedMessage(taskId: nil, title: "Fix"), "Fix")
    }
}
