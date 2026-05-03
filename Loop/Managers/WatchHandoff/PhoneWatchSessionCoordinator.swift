//
//  PhoneWatchSessionCoordinator.swift
//  Loop (iOS)
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
    /// Shared accessor populated by LoopAppManager at launch. SwiftUI views that
    /// don't have direct access to LoopAppManager (e.g., SettingsView, which
    /// receives its view model from above) read this accessor to observe state.
    /// Optional; may be nil during initial app boot or in test contexts.
    static weak var shared: PhoneWatchSessionCoordinator?

    @Published private(set) var lastHeartbeatReceivedAt: Date?
    @Published private(set) var lastHeartbeatSentAt: Date?
    @Published private(set) var isCounterpartReachable: Bool = false

    // B.8: widened from `private` to internal so LoopAppManager can cast it
    // to `WCSessionPhoneWatchTransport` (the concrete type that conforms to
    // `SnapshotTransport`) when wiring `AlgorithmStateSnapshotEmitter`.
    var transport: PhoneWatchTransport
    private let appBuildNumber: String
    private let clock: () -> Date
    private var heartbeat: HeartbeatScheduler?

    /// B.5 Issue #5: log channel for split-brain detection (advisory only on iOS).
    private let log = OSLog(category: "PhoneWatchSessionCoordinator")

    /// B.2.d: orchestrator subscribes to incoming non-heartbeat messages
    /// (modeSwitch / pairingHandoff). The coordinator continues to handle
    /// heartbeat internally; modeSwitch / pairingHandoff are forwarded.
    var onHandoffMessage: ((PhoneWatchMessage) -> Void)?

    /// B.2.d: convenience reachability surface for HandoffPolicyEngine.
    var isReachable: Bool {
        return isCounterpartReachable
    }

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

    /// B.2.d: queue a mode-switch message (transferUserInfo, fire-and-forget).
    func sendModeSwitch(_ ms: PhoneWatchModeSwitch) {
        transport.queueMessage(.modeSwitch(ms))
    }

    /// B.2.d: queue a pairing-handoff message (transferUserInfo).
    func sendPairingHandoff(_ ph: PhoneWatchPairingHandoff) {
        transport.queueMessage(.pairingHandoff(ph))
    }

    /// B.3.a Phase 6: queue a settings-sync message (transferUserInfo).
    func sendSettingsSync(_ sync: PhoneWatchSettingsSync) {
        transport.queueMessage(.settingsSync(sync))
    }

    func sendHeartbeat() {
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock(),
            senderRole: .phone,
            appBuildNumber: appBuildNumber,
            claimedOwner: HandoffOrchestrator.shared?.handoffState.currentOwner  // B.5 Issue #5
        )
        transport.sendMessage(.heartbeat(hb), reply: nil, onError: { _ in })
        lastHeartbeatSentAt = clock()
        isCounterpartReachable = transport.isReachable
    }

    /// For debug-echo (long-press on Settings row). Sends a heartbeat with an
    /// expected reply; on success, returns the round-trip time via the closure.
    func sendDebugEcho(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        let now = clock()
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now, senderRole: .phone, appBuildNumber: appBuildNumber,
            claimedOwner: HandoffOrchestrator.shared?.handoffState.currentOwner  // B.5 Issue #5
        )
        transport.sendMessage(.heartbeat(hb), reply: { result in
            switch result {
            case .success:
                DispatchQueue.main.async {
                    completion(.success(self.clock().timeIntervalSince(now)))
                }
            case .failure(let err):
                DispatchQueue.main.async { completion(.failure(err)) }
            }
        }, onError: { err in
            DispatchQueue.main.async { completion(.failure(err)) }
        })
    }

    private func handle(incoming message: PhoneWatchMessage) {
        switch message {
        case .heartbeat(let hb):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: hb.protocolVersion) else { return }
            lastHeartbeatReceivedAt = clock()
            isCounterpartReachable = true

            // B.5 Issue #5: split-brain detection (advisory on phone). Phone-wins
            // arbitration means the phone keeps owning if both sides think they
            // own — log a warning but don't demote, since the watch will silently
            // demote on its receipt of our heartbeat.
            if let orch = HandoffOrchestrator.shared,
               orch.handoffState.currentOwner == .phone,
               hb.claimedOwner == .watch {
                log.error("split-brain detected (advisory): watch heartbeat claims watch is owner; phone retains ownership per arbitration rule")
            }
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
        case .settingsSync:
            // Settings sync is phone → watch only; the phone never receives one.
            // No-op to avoid a compiler warning on the exhaustive switch.
            break
        case .algorithmStateSnapshot:
            // B.8 prep: snapshots are phone → watch only; the phone never
            // receives one. No-op to keep the switch exhaustive.
            break
        }
    }
}
