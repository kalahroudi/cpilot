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

    // MARK: Keys

    func testAKeyGivesBackTheRepositoryItCameFrom() {
        for r in [ref("/code/app"), ref("/code/app", "srv"), ref("/code/a|b", "srv"), ref("/")] {
            XCTAssertEqual(RepoRef(key: r.key), r)
        }
        XCTAssertNil(RepoRef(key: "no-separator"))
    }

    // MARK: Saved spec runs

    private func hands(_ extra: (inout SpecRunEntry) -> Void = { _ in }) -> SpecRunEntry { var e = SpecRunEntry(autonomy: "hands"); extra(&e); return e }

    func testAnIdleSpecIsNotKept() {
        var st = SpecRunState()
        st.set(SpecRunEntry(autonomy: "step"), "001", in: "a")
        XCTAssertFalse(st.hasWork(in: "a"))
        st.set(SpecRunEntry(autonomy: "step", gate: true), "001", in: "a")
        XCTAssertTrue(st.hasWork(in: "a"), "waiting for 'start building' is kept")
        st.set(SpecRunEntry(autonomy: "step"), "001", in: "a")
        XCTAssertEqual(st, SpecRunState(), "going idle forgets it, and the repository with it")
    }

    func testEachThingWorthKeepingKeepsTheEntry() {
        for e in [hands(), SpecRunEntry(autonomy: "plan", stage: "plan"), SpecRunEntry(autonomy: "step", draftStage: "specify", draftText: "# Spec")] {
            XCTAssertFalse(e.isIdle)
        }
    }

    func testSpecsArePerRepositoryAndListedInOrder() {
        var st = SpecRunState()
        st.set(hands(), "002", in: "a"); st.set(hands(), "001", in: "a"); st.set(hands(), "001", in: "b")
        XCTAssertEqual(st.pending(in: "a").map(\.id), ["001", "002"])
        XCTAssertEqual(st.scopes, ["a", "b"])
        XCTAssertNil(st.entry("002", in: "b"), "the same id in another repository is another spec")
        st.remove("001", in: "a"); st.remove("nope", in: "a"); st.remove("x", in: "other")
        XCTAssertEqual(st.pending(in: "a").map(\.id), ["002"])
    }

    func testSavedRunsSurviveARestartWithDraftsAndAttempts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)/spec-runs.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var st = SpecRunState()
        st.set(SpecRunEntry(autonomy: "hands", stage: "tasks", attempts: 2), "001-login", in: "/code/app|")
        st.set(SpecRunEntry(autonomy: "step", draftStage: "specify", draftText: "# Spec\nwith “quotes” and\nlines"), "003-export", in: "/code/api|srv")
        st.save(to: url)
        let back = SpecRunState.load(from: url)
        XCTAssertEqual(back, st)
        XCTAssertEqual(back.entry("003-export", in: "/code/api|srv")?.draftText, "# Spec\nwith “quotes” and\nlines")
        XCTAssertEqual(back.entry("001-login", in: "/code/app|")?.attempts, 2)
    }

    func testAMissingOrDamagedFileStartsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(SpecRunState.load(from: dir.appendingPathComponent("none.json")), SpecRunState())
        let bad = dir.appendingPathComponent("bad.json"); try "{ not json".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertEqual(SpecRunState.load(from: bad), SpecRunState())
    }

    // MARK: What to do with a saved spec

    func testResumeDecisions() {
        func d(_ e: SpecRunEntry, exists: Bool = true, spec: Bool = true, draft: Bool = false) -> SpecResume.Action {
            SpecResume.decide(e, docExists: exists, hasSpec: spec, hasDraft: draft)
        }
        XCTAssertEqual(d(hands(), exists: false), .drop, "its folder is gone")
        XCTAssertEqual(d(hands()), .build)
        XCTAssertEqual(d(SpecRunEntry(autonomy: "plan", gate: true)), .wait, "plan-for-me stops for your go-ahead")
        XCTAssertEqual(d(SpecRunEntry(autonomy: "step", draftStage: "plan", draftText: "x"), draft: true), .review)
        XCTAssertEqual(d(hands { $0.stage = "tasks" }), .rewrite(stage: "tasks", attempts: 1))
        XCTAssertEqual(d(hands { $0.stage = "plan"; $0.attempts = 2 }), .rewrite(stage: "plan", attempts: 3))
        XCTAssertEqual(d(hands { $0.stage = "plan"; $0.attempts = 3 }), .giveUp(stage: "plan", attempts: 3), "it does not loop forever")
        XCTAssertEqual(d(hands { $0.stage = "specify" }, spec: false), .rewrite(stage: "specify", attempts: 1), "the spec was never written")
        XCTAssertEqual(d(hands { $0.stage = "specify" }, spec: true), .settle, "an answer round cut short leaves the spec on disk alone")
    }

    func testAWrittenDraftIsReviewedBeforeAnInterruptedStageIsRewritten() {
        let e = SpecRunEntry(autonomy: "hands", stage: "plan", draftStage: "specify", draftText: "# Spec")
        XCTAssertEqual(SpecResume.decide(e, docExists: true, hasSpec: false, hasDraft: true), .review)
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
