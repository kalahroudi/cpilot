// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// The first human checkpoint of tests-first work: "Is this what you want built?". An independent reviewer reads the spec for gaps; a spec with nothing found goes on by itself (if Settings allow),
/// anything else becomes a card that says what was found and why it matters.
extension SpecCenter {
    private static let reviewedKey = "specReviewed"

    struct ReviewPayload: Codable {
        var spec: String
        var dir: String
        var environment: String?
        var hash: String
        var result: SpecReview.Result
    }

    private var scopeKey: String { repo.map { RepoRef(dir: $0.dir, environment: $0.environment).key } ?? "" }
    private func reviewedHashes() -> [String: String] { UserDefaults.standard.dictionary(forKey: Self.reviewedKey) as? [String: String] ?? [:] }
    private func reviewedKeyFor(_ id: String) -> String { "\(scopeKey)|\(id)" }
    func markReviewed(_ id: String, hash: String) { var d = reviewedHashes(); d[reviewedKeyFor(id)] = hash; UserDefaults.standard.set(d, forKey: Self.reviewedKey) }

    /// Reviews the spec once per version of its text. True when the spec must wait for a person.
    func reviewSpec(_ id: String) async -> Bool {
        guard Prefs.shared.testFirst != "off", Prefs.shared.specReview, let r = repo, let d = doc(id), let spec = d.spec, !spec.isEmpty else { return false }
        let hash = SpecReview.hash(spec)
        if reviewedHashes()[reviewedKeyFor(id)] == hash { return false }
        let waiting = Workspace.shared.proposals.open(kind: "spec_review", scope: scopeKey).contains { (try? JSONDecoder().decode(ReviewPayload.self, from: Data($0.payload.utf8)))?.spec == id }
        if waiting { return true }

        let invariants = await readInvariants(r)
        let model = [Prefs.shared.specReviewModel, Prefs.shared.reviewerModel].first { !$0.isEmpty } ?? "sonnet"
        guard let answer = await ClaudeOneShot.run(SpecReview.prompt(spec: spec, invariants: invariants), in: r.dir, model: model, timeout: 240),
              let result = SpecReview.parse(answer, spec: spec) else {
            AppModel.shared.show("The spec review could not run, so \"\(d.title)\" goes on without it.", error: true)
            return false
        }
        let title = d.title
        if result.isClean, d.openQuestions.isEmpty, Prefs.shared.specAutoApprove {
            markReviewed(id, hash: hash)
            Workspace.shared.audit.record(AuditEntry(session: "spec-review", tool: "spec review", summary: "\(title): nothing found, approved by rule", outcome: "allowed by rule"))
            AppModel.shared.show("The review of \"\(title)\" found nothing, so it goes on.")
            return false
        }
        let payload = (try? JSONEncoder().encode(ReviewPayload(spec: id, dir: r.dir, environment: r.environment, hash: hash, result: result))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Workspace.shared.proposals.add(SpecReview.card(title: title, result: result, scope: scopeKey, payload: payload))
        AppModel.shared.notify("\"\(title)\" needs your yes", body: "A reviewer read the spec before any tests were written. Open Specs to see what it found.", project: projectName)
        NotificationCenter.default.post(name: Dreamer.changed, object: nil)
        return true
    }

    /// A person approved: the findings go into the spec, and planning goes on. Returns the reason it could not, or nil.
    func approveSpecReview(_ proposal: Proposal) async -> String? {
        guard let p = try? JSONDecoder().decode(ReviewPayload.self, from: Data(proposal.payload.utf8)), let d = doc(p.spec) else { return "That spec is gone." }
        guard let current = d.spec, SpecReview.hash(current) == p.hash else {
            Workspace.shared.proposals.decide(proposal.id, .stale, by: "you", outcome: "The spec changed after it was reviewed.")
            return "The spec changed after it was reviewed, so this review is out of date. It is reviewed again when you move on."
        }
        let updated = SpecReview.applying(p.result, to: current)
        await save(p.spec, file: "spec.md", text: updated)
        markReviewed(p.spec, hash: SpecReview.hash(updated))
        Workspace.shared.proposals.decide(proposal.id, .applied, by: "you")
        Workspace.shared.audit.record(AuditEntry(session: "spec-review", tool: "spec review", summary: "\(d.title): \(p.result.findings.count) finding(s) added to the spec", outcome: "allowed once"))
        await advance(p.spec, after: .specify)
        return nil
    }
}

/// What the Approve and decline buttons of each kind of proposal do.
@MainActor
enum ProposalActions {
    /// Labels for the two buttons, in words that say what they do.
    static func labels(_ p: Proposal) -> (approve: String, decline: String) {
        switch p.kind {
        case "spec_review": ("Approve the spec", "Let me change it")
        case "test_dispute": ("Unlock the tests", "Keep them locked")
        default: ("Approve", "Not now")
        }
    }

    private static func center(dir: String, environment: String?) -> SpecCenter { SpecHub.shared.center(for: PRCenter.Repo(dir: dir, environment: environment)) }

    /// Returns why it could not be done, or nil.
    static func approve(_ p: Proposal) async -> String? {
        switch p.kind {
        case "dream": return await Dreamer.shared.approve(p.id, by: "you")
        case "spec_review":
            guard let pl = try? JSONDecoder().decode(SpecCenter.ReviewPayload.self, from: Data(p.payload.utf8)) else { return "That proposal cannot be read." }
            return await center(dir: pl.dir, environment: pl.environment).approveSpecReview(p)
        case "test_dispute":
            guard let pl = try? JSONDecoder().decode(SpecCenter.DisputePayload.self, from: Data(p.payload.utf8)) else { return "That proposal cannot be read." }
            await center(dir: pl.dir, environment: pl.environment).releaseLock(pl.spec, pl.task)
            Workspace.shared.proposals.decide(p.id, .applied, by: "you")
            return nil
        default: return "Nothing knows how to carry out this proposal."
        }
    }

    static func decline(_ p: Proposal) async {
        switch p.kind {
        case "dream": Dreamer.shared.decline(p.id)
        case "test_dispute":
            if let pl = try? JSONDecoder().decode(SpecCenter.DisputePayload.self, from: Data(p.payload.utf8)) { center(dir: pl.dir, environment: pl.environment).keepLock(pl.spec, pl.task) }
            Workspace.shared.proposals.decide(p.id, .declined, by: "you")
        default: Workspace.shared.proposals.decide(p.id, .declined, by: "you")
        }
    }
}
