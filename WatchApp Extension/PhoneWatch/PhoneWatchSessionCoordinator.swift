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
import os.log

@MainActor
final class PhoneWatchSessionCoordinator: ObservableObject {
    @Published private(set) var lastHeartbeatReceivedAt: Date?
    @Published private(set) var lastHeartbeatSentAt: Date?
    @Published private(set) var isCounterpartReachable: Bool = false

    private var transport: PhoneWatchTransport
    private let appBuildNumber: String
    private let clock: () -> Date
    private var heartbeat: HeartbeatScheduler?

    /// B.5 Issue #5: log channel for split-brain detection.
    private let log = OSLog(category: "PhoneWatchSessionCoordinator")

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
            appBuildNumber: appBuildNumber,
            claimedOwner: HandoffOrchestrator.shared?.handoffState.currentOwner  // B.5 Issue #5
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

            // split-brain detection. If we (the watch) think
            // we're the owner AND the inbound heartbeat says the phone also
            // thinks it's the owner, that's split-brain. Phone-wins
            // arbitration: silently demote ourselves (commands off + emit a
            // userRequestHandoff(.phone) so the state machine reverts).
            if let orch = HandoffOrchestrator.shared,
               orch.handoffState.currentOwner == .watch,
               hb.claimedOwner == .phone {
                log.error("split-brain detected: I (watch) believe I'm owner, but phone heartbeat claims phone is owner; phone wins, demoting self")
                orch.ownership.commandsAllowed = false   // immediate gate
                orch.userRequestHandoff(to: .phone)      // emit transition request
            }
        case .modeSwitch(let ms):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ms.protocolVersion) else { return }
            log.default("received mode switch %{public}@ (transition %{public}@)",
                        String(describing: ms.targetMode.rawValue),
                        ms.transitionId.uuidString)
            // forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        case .pairingHandoff(let ph):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ph.protocolVersion) else { return }
            log.default("received pairing handoff for pod %{public}@ (%d bytes)",
                        ph.podId,
                        ph.pairingPayload.count)
            // forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        case .settingsSync(let sync):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: sync.protocolVersion) else { return }
            log.default("received settings sync (protocolVersion=%d)", sync.protocolVersion)
            // B.3.a Phase 6: store in the shared cache so bootstraps can read it.
            WatchSettingsCache.shared.update(sync)
        case .algorithmStateSnapshot(let snap):
            // No per-payload protocolVersion check: AlgorithmStateSnapshot has no
            // version field of its own. Schema compatibility is enforced at envelope
            // (PhoneWatchMessage) decode time — older receivers throw on the unknown
            // .algorithmStateSnapshot Kind raw value before the payload is parsed.
            log.default("received algorithm-state snapshot %{public}@ (createdAt=%{public}@)",
                        snap.snapshotID.uuidString,
                        String(describing: snap.createdAt))
            WatchAlgorithmSnapshotCache.shared.update(snap)
        case .algorithmStateSnapshotPointer:
            // ExtensionDelegate.handlePhoneWatchMessageData converts
            // pointer messages into inline `.algorithmStateSnapshot` messages
            // (after reading the file from the App Group container) before
            // forwarding them to the transport. So this branch is unreachable
            // in production — kept as a defensive no-op so the switch stays
            // exhaustive. If this ever fires, log it loudly: it means the
            // pointer slipped past the rewrap shim.
            log.error("unexpected algorithmStateSnapshotPointer at coordinator — pointer should have been re-wrapped at ExtensionDelegate")
        }
    }
}
