// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import IOKit.pwr_mgt
import CPilotKit

/// Lets a paired phone see and steer CPilot. It is a small web server that listens on 127.0.0.1 only; a `RemoteTransport` (Tailscale) publishes it on the
/// tailnet over HTTPS, so nothing is open to the internet and nothing but a paired device's token gets past the front door.
/// What a phone may do is narrower than what you may do at the Mac: see `RemoteAPI`.
@MainActor @Observable
final class RemoteServer {
    static let shared = RemoteServer()
    /// The loopback port. A development build can use another (`CPILOT_REMOTE_PORT`) so it does not clash with the installed app.
    static let port = ProcessInfo.processInfo.environment["CPILOT_REMOTE_PORT"].flatMap { Int($0) } ?? 47821

    enum Status: Equatable { case off, starting, on(URL), failed(String) }
    private(set) var status: Status = .off

    let devices = RemoteDeviceStore()
    /// This Mac's identity toward push services; made once.
    let vapid = VAPIDKeys.loadOrCreate()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var transport: RemoteTransport = ProcessInfo.processInfo.environment["CPILOT_REMOTE_LOCAL"] != nil ? LocalTransport() : TailscaleTransport()
    @ObservationIgnored private var streams: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var lastState = ""
    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    @ObservationIgnored private var ticks = 0

    var url: URL? { if case .on(let u) = status { return u }; return nil }

    // MARK: Life cycle

    func start() async {
        guard listener == nil else { return }
        status = .starting
        do {
            try await listen()
            let url = try await transport.start(port: Self.port)
            status = .on(url)
            pulse = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); self?.pulseTick() }
            }
        } catch {
            stopListening()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        pulse?.cancel(); pulse = nil
        stopListening()
        await transport.stop()
        releaseAssertion()
        status = .off
    }

    private func stopListening() {
        listener?.cancel(); listener = nil
        for c in streams.values { c.cancel() }
        streams.removeAll()
    }

    private func listen() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(Self.port))!)
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.first() { c.resume() }
                case .failed(let e): if once.first() { c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
        }
        l.stateUpdateHandler = nil
        listener = l
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPParser.parse(buf) {
            case .request(let req): Task { @MainActor in await self.serve(req, on: conn) }
            case .tooLarge: Self.send(conn, .error(413, "Too large."))
            case .bad: Self.send(conn, .error(400, "Bad request."))
            case .incomplete:
                if done || err != nil { conn.cancel() } else { Task { @MainActor in self.receive(conn, buffer: buf) } }
            }
        }
    }

    nonisolated private static func send(_ conn: NWConnection, _ r: HTTPResponse) {
        conn.send(content: r.serialized(), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serve(_ req: HTTPRequest, on conn: NWConnection) async {
        let out = await RemoteAPI.route(req, server: self)
        switch out {
        case .response(let r): Self.send(conn, r)
        case .events:
            let first = currentState()
            lastState = first
            conn.send(content: HTTPResponse.sseHead + HTTPResponse.sseEvent("state", first), completion: .contentProcessed { _ in })
            let key = ObjectIdentifier(conn)
            streams[key] = conn
            conn.stateUpdateHandler = { [weak self] s in
                switch s { case .failed, .cancelled: Task { @MainActor in self?.streams[key] = nil }; default: break }
            }
        }
    }

    // MARK: State pushed to phones

    func currentState() -> String { RemoteAPI.stateJSON() }

    /// Once a second: tell connected phones when anything they show has changed, keep the streams alive, and keep the Mac awake while agents work.
    private func pulseTick() {
        ticks += 1
        if !streams.isEmpty {
            let s = currentState()
            if s != lastState {
                lastState = s
                for c in streams.values { c.send(content: HTTPResponse.sseEvent("state", s), completion: .contentProcessed { _ in }) }
            } else if ticks % 15 == 0 {
                for c in streams.values { c.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed { _ in }) }
            }
        }
        if ticks % 5 == 0 { updateAssertion() }
    }

    /// A Mac that sleeps with agents working would make the phone useless, so hold off idle sleep while remote access is on and something is running.
    private func updateAssertion() {
        let working = Workspace.shared.runningCount > 0 || !ApprovalBroker.shared.pending.isEmpty
        if working, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "CPilot remote access: agents are working" as CFString, &assertion)
        } else if !working { releaseAssertion() }
    }

    private func releaseAssertion() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }
}

/// True the first time it is asked, so a continuation is resumed once however many state updates arrive.
private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
