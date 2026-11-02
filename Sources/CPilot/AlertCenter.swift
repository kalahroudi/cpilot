// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Tells paired phones that something needs them while they are away from the page: an approval is waiting, a session failed, a run finished.
/// The message goes from this Mac straight to the phone's push service (Apple, Google or Mozilla), encrypted so that only that phone can read it.
/// It says what and where, never code. A phone that is looking at the page is not pushed to, because the page already shows it.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()
    private var recent: [String: Date] = [:]
    /// What happened to the last alert for each phone, shown on the Device tab.
    private(set) var last: [String: (at: Date, result: String)] = [:]

    private var allowLoopback: Bool { ProcessInfo.processInfo.environment["CPILOT_REMOTE_LOCAL"] != nil }
    /// The same alert (same tag) is sent at most once a minute.
    static let quiet: TimeInterval = 60

    func alert(_ kind: AlertKind, title: String, body: String, tag: String, session: String? = nil) {
        let server = RemoteServer.shared
        guard let base = server.url else { return }
        let now = Date()
        if let t = recent[tag], now.timeIntervalSince(t) < Self.quiet { return }
        recent[tag] = now
        recent = recent.filter { now.timeIntervalSince($0.value) < 600 }
        let devices = server.devices.recipients(for: kind)
        guard !devices.isEmpty else { return }
        let message = Self.payload(title: title, body: body, tag: tag, url: session.map { "/#s=\($0)" } ?? "/")
        for d in devices { Task { _ = await send(message, to: d, subject: base.absoluteString) } }
    }

    /// One message to one phone, whatever its settings say. Forgets a subscription the push service says is gone.
    @discardableResult
    func send(_ message: Data, to d: RemoteDevice, subject: String) async -> PushResult {
        guard let sub = d.push, sub.isAcceptable(allowLoopback: allowLoopback) else { return .failed("No usable subscription.") }
        let result = await WebPushSender.send(message, to: sub, keys: RemoteServer.shared.vapid, subject: subject)
        switch result {
        case .sent: last[d.id] = (Date(), "sent")
        case .gone: last[d.id] = (Date(), "the phone unsubscribed"); RemoteServer.shared.devices.setPush(d.id, nil)
        case .failed(let why): last[d.id] = (Date(), "failed: \(why)")
        }
        return result
    }

    static func payload(title: String, body: String, tag: String, url: String) -> Data {
        let o: [String: Any] = ["title": String(title.prefix(80)), "body": String(body.prefix(160)), "tag": tag, "url": url]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    // MARK: What raises an alert

    /// A session finished a turn. Failures and approvals have their own alerts; what is left is a run that is done: one started from a phone or a trigger,
    /// or a chief pilot with nothing in flight (it ends its turn while it waits on work, which is not done).
    func turnEnded(_ c: SessionController) {
        if case .failed = c.state { return }
        guard c.pending.isEmpty else { return }
        let branch = c.meta.branch ?? ""
        let own = branch.hasPrefix("phone/") || branch.hasPrefix("trigger/")
        let chiefDone = c.meta.chief == true && !(ChiefWaker.shared.entries[c.meta.cwd]?.expecting ?? false) && !ChiefWaker.workInFlight(repo: c.meta.cwd, chiefId: c.id)
        guard own || chiefDone else { return }
        let last = c.items.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text ?? ""
        let line = last.split(separator: "\n").first.map { String($0.prefix(140)) } ?? "Done."
        alert(.finished, title: "\(c.meta.title) finished", body: line, tag: "done-\(c.id)", session: c.id)
    }
}
