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

    // MARK: Subfolders

    func testSubfoldersCollapseIntoTheirRepositoryKeepingOrder() {
        let refs = [ref("/code/app/web"), ref("/code/api"), ref("/code/app"), ref("/code/app/server")]
        let roots = [ref("/code/app/web").key: "/code/app", ref("/code/app").key: "/code/app", ref("/code/app/server").key: "/code/app", ref("/code/api").key: "/code/api"]
        XCTAssertEqual(RepoRef.collapse(refs, roots: roots), [ref("/code/app"), ref("/code/api")])
    }

    func testAFolderNotLookedUpYetStaysAsItIs() {
        XCTAssertEqual(RepoRef.collapse([ref("/code/app/web")], roots: [:]), [ref("/code/app/web")])
    }

    func testTheSameTopFolderOnAServerIsNotMergedWithThisMac() {
        let refs = [ref("/code/app/web"), ref("/code/app/web", "srv")]
        let roots = [refs[0].key: "/code/app", refs[1].key: "/code/app"]
        XCTAssertEqual(RepoRef.collapse(refs, roots: roots), [ref("/code/app"), ref("/code/app", "srv")])
    }

    func testContainsMatchesTheFolderAndWhatIsInsideItOnly() {
        let r = ref("/code/app")
        XCTAssertTrue(r.contains("/code/app"))
        XCTAssertTrue(r.contains("/code/app/web/src"))
        XCTAssertFalse(r.contains("/code/app-two"), "a folder that merely starts with the same letters is another repository")
        XCTAssertFalse(r.contains("/code"))
        XCTAssertTrue(ref("/code/app/").contains("/code/app/web"))
    }

    // MARK: Work waiting for a repository

    func testWorkWaitsForItsOwnRepositoryAndIsHandedOverOnce() {
        var q = ResumeQueue()
        q.hold("001", in: "a"); q.hold("001", in: "a"); q.hold("002", in: "a"); q.hold("001", in: "b")
        XCTAssertTrue(q.holds("a"))
        XCTAssertEqual(q.take(for: "a"), ["001", "002"], "once each, in the order they arrived")
        XCTAssertEqual(q.take(for: "a"), [])
        XCTAssertFalse(q.holds("a"))
        XCTAssertEqual(q.take(for: "b"), ["001"])
        XCTAssertEqual(q.take(for: "never"), [])
    }

    // MARK: Polling load

    func testOnlyTheRepositoryWithRunningChecksIsAskedEveryMinute() {
        var p = PollSchedule(pending: 60, idle: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(p.isDue("busy", now: t0), "a repository never asked is due")
        p.record("busy", hasPending: true, now: t0)
        p.record("quiet", hasPending: false, now: t0)
        XCTAssertFalse(p.isDue("busy", now: t0.addingTimeInterval(59)))
        XCTAssertTrue(p.isDue("busy", now: t0.addingTimeInterval(60)))
        XCTAssertFalse(p.isDue("quiet", now: t0.addingTimeInterval(60)), "the others wait while one builds")
        XCTAssertFalse(p.isDue("quiet", now: t0.addingTimeInterval(599)))
        XCTAssertTrue(p.isDue("quiet", now: t0.addingTimeInterval(600)))
    }

    func testManyRepositoriesCostOneRequestEachPerIdleWindow() {
        var p = PollSchedule(pending: 60, idle: 600)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let keys = (0..<30).map { "repo\($0)" }
        var requests = 0
        for m in 0..<10 {                                    // ten minutes of one-minute ticks; only repo0 has a running check
            let now = t0.addingTimeInterval(Double(m) * 60)
            for k in keys where p.isDue(k, now: now) { requests += 1; p.record(k, hasPending: k == "repo0", now: now) }
        }
        XCTAssertEqual(requests, 30 + 9, "everyone once, then only the busy one each minute")
    }

    func testAnUnreadableRepositoryIsLeftAloneAndForgottenWhenGone() {
        var p = PollSchedule()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        p.postpone("locked", by: 3600, now: t0)
        XCTAssertFalse(p.isDue("locked", now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(p.isDue("locked", now: t0.addingTimeInterval(3600)))
        p.keep(only: [])
        XCTAssertTrue(p.isDue("locked", now: t0), "a repository that left the list starts fresh if it returns")
    }
}
