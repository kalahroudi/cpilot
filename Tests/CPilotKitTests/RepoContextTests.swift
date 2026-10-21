// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class RepoContextTests: XCTestCase {
    private func ref(_ dir: String, _ env: String? = nil) -> RepoRef { RepoRef(dir: dir, environment: env) }

    // MARK: Identity

    func testSameFolderOnAServerIsAnotherRepository() {
        XCTAssertNotEqual(ref("/code/app").key, ref("/code/app", "srv").key)
        XCTAssertEqual(ref("/code/app").key, ref("/code/app", nil).key)
    }

    // MARK: Labels

    func testUniqueNamesStayShort() {
        let l = RepoLabels.labels([ref("/code/app"), ref("/code/api")])
        XCTAssertEqual(l[ref("/code/app")], "app")
        XCTAssertEqual(l[ref("/code/api")], "api")
    }

    func testSameNameIsToldApartByParentFolder() {
        let l = RepoLabels.labels([ref("/work/app"), ref("/personal/app"), ref("/work/api")])
        XCTAssertEqual(l[ref("/work/app")], "work/app")
        XCTAssertEqual(l[ref("/personal/app")], "personal/app")
        XCTAssertEqual(l[ref("/work/api")], "api", "a repository that is already unique is not lengthened")
    }

    func testDeepensUntilTheyDiffer() {
        let l = RepoLabels.labels([ref("/a/x/app"), ref("/b/x/app")])
        XCTAssertEqual(l[ref("/a/x/app")], "a/x/app")
        XCTAssertEqual(l[ref("/b/x/app")], "b/x/app")
    }

    func testServerNameIsShownAndSeparatesOtherwiseEqualRepositories() {
        let l = RepoLabels.labels([ref("/code/app"), ref("/code/app", "srv")]) { $0 == "srv" ? "Build box" : nil }
        XCTAssertEqual(l[ref("/code/app")], "app")
        XCTAssertEqual(l[ref("/code/app", "srv")], "app · Build box")
    }

    func testNoClashLoopsForeverOnIdenticalInput() {
        let l = RepoLabels.labels([ref("/code/app"), ref("/code/app")])
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(RepoLabels.labels([]).count, 0)
        XCTAssertEqual(RepoLabels.labels([ref("/")])[ref("/")], "/")
    }

    // MARK: Per-repository state

    struct Job: Equatable { var running = false; var draft: String?; var error: String? }

    func testTheSameIdInTwoRepositoriesIsTwoJobs() {
        var s = ScopedStore<Job>()
        s["a", "001-login"] = Job(running: true)
        s["b", "001-login"] = Job(draft: "plan")
        XCTAssertEqual(s["a", "001-login"], Job(running: true))
        XCTAssertEqual(s["b", "001-login"], Job(draft: "plan"))
        XCTAssertEqual(s.all(in: "a").count, 1)
        XCTAssertTrue(s.all(in: "c").isEmpty)
    }

    func testAStageFinishingAfterASwitchLandsInItsOwnRepository() {
        var s = ScopedStore<Job>()
        let started = "a"
        s.modify(started, "001", new: Job()) { $0.running = true }
        var current = "a"
        current = "b"                                       // the user switches repository while the agent works
        s.modifyExisting(started, "001") { $0.running = false; $0.draft = "spec text" }
        XCTAssertEqual(s["a", "001"], Job(running: false, draft: "spec text"))
        XCTAssertNil(s["b", "001"], "nothing leaks into the repository that is now showing")
        XCTAssertTrue(s.all(in: current).isEmpty)
    }

    func testLateNewsDoesNotBringBackAJobThatIsGone() {
        var s = ScopedStore<Job>()
        s.modifyExisting("a", "001") { $0.running = true }
        XCTAssertNil(s["a", "001"])
        s.modify("a", "001", new: Job()) { $0.error = "failed" }
        XCTAssertEqual(s["a", "001"]?.error, "failed")
        s["a", "001"] = nil
        XCTAssertTrue(s.all(in: "a").isEmpty)
    }
}
