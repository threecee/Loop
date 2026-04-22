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

@MainActor
final class PhoneWatchSessionCoordinator: ObservableObject {
    @Published private(set) var lastHeartbeatReceivedAt: Date?
    @Published private(set) var lastHeartbeatSentAt: Date?
    @Published private(set) var isCounterpartReachable: Bool = false

    private var transport: PhoneWatchTransport
    private let appBuildNumber: String
    private let clock: () -> Date
    private var heartbeat: HeartbeatScheduler?

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

    func sendHeartbeat() {
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock(),
            senderRole: .phone,
            appBuildNumber: appBuildNumber
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
            sentAt: now, senderRole: .phone, appBuildNumber: appBuildNumber
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
        case .modeSwitch(let ms):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ms.protocolVersion) else { return }
            NSLog("PhoneWatchSessionCoordinator: received mode switch \(ms.targetMode.rawValue) (transition \(ms.transitionId))")
        case .pairingHandoff(let ph):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ph.protocolVersion) else { return }
            NSLog("PhoneWatchSessionCoordinator: received pairing handoff for pod \(ph.podId) (\(ph.pairingPayload.count) bytes)")
        }
    }
}
