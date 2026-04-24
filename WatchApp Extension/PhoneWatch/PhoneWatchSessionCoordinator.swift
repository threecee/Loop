//
//  PhoneWatchSessionCoordinator.swift
//  LoopWatchApp (watchOS)
//
//  Owns the PhoneWatchTransport; exposes connection state via @Published
//  properties; dispatches incoming messages to type-specific stub handlers
//  (log-only in B.2.c; real behavior lands in B.2.d/e).
//

import Foundation
import OmniBLE
import Combine

@MainActor
final class PhoneWatchSessionCoordinator: ObservableObject {
    @Published private(set) var lastHeartbeatReceivedAt: Date?
    @Published private(set) var lastHeartbeatSentAt: Date?
    @Published private(set) var isCounterpartReachable: Bool = false

    private var transport: PhoneWatchTransport
    private let appBuildNumber: String
    private let clock: () -> Date
    private var heartbeat: HeartbeatScheduler?

    /// B.2.d: orchestrator subscribes to incoming non-heartbeat messages
    /// (modeSwitch / pairingHandoff). The coordinator continues to handle
    /// heartbeat internally; modeSwitch / pairingHandoff are forwarded.
    var onHandoffMessage: ((PhoneWatchMessage) -> Void)?

    /// B.2.d: convenience reachability for HandoffPolicyEngine. Mirrors the
    /// underlying transport's WCSession reachability when known, else false.
    var isReachable: Bool {
        // isCounterpartReachable already tracks transport.isReachable updated
        // on each sent heartbeat; surface as isReachable for orchestrator
        // observation. When no heartbeat has been sent yet, defaults to false.
        return isCounterpartReachable
    }

    /// "Connected" = we received a heartbeat within the last 90 seconds.
    var isConnected: Bool {
        guard let when = lastHeartbeatReceivedAt else { return false }
        return clock().timeIntervalSince(when) < 90
    }

    init(transport: PhoneWatchTransport,
         appBuildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
         clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.appBuildNumber = appBuildNumber
        self.clock = clock
    }

    func start() {
        transport.onIncomingMessage = { [weak self] message in
            Task { @MainActor in self?.handle(incoming: message) }
        }
        heartbeat = HeartbeatScheduler(interval: 30) { [weak self] in
            Task { @MainActor in self?.sendHeartbeat() }
        }
        heartbeat?.start()
    }

    func stop() {
        heartbeat?.stop()
        heartbeat = nil
    }

    // MARK: - Send

    /// B.2.d: queue a mode-switch message (transferUserInfo, fire-and-forget).
    func sendModeSwitch(_ ms: PhoneWatchModeSwitch) {
        transport.queueMessage(.modeSwitch(ms))
    }

    /// B.2.d: queue a pairing-handoff message (transferUserInfo).
    func sendPairingHandoff(_ ph: PhoneWatchPairingHandoff) {
        transport.queueMessage(.pairingHandoff(ph))
    }

    func sendHeartbeat() {
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock(),
            senderRole: .watch,
            appBuildNumber: appBuildNumber
        )
        transport.sendMessage(.heartbeat(hb), reply: nil, onError: { _ in })
        lastHeartbeatSentAt = clock()
        isCounterpartReachable = transport.isReachable
    }

    // MARK: - Receive

    private func handle(incoming message: PhoneWatchMessage) {
        switch message {
        case .heartbeat(let hb):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: hb.protocolVersion) else { return }
            lastHeartbeatReceivedAt = clock()
            isCounterpartReachable = true
        case .modeSwitch(let ms):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ms.protocolVersion) else { return }
            NSLog("PhoneWatchSessionCoordinator: received mode switch \(ms.targetMode.rawValue) (transition \(ms.transitionId))")
            // B.2.d: forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        case .pairingHandoff(let ph):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ph.protocolVersion) else { return }
            NSLog("PhoneWatchSessionCoordinator: received pairing handoff for pod \(ph.podId) (\(ph.pairingPayload.count) bytes)")
            // B.2.d: forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        }
    }
}
