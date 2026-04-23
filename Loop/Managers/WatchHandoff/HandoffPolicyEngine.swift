//
//  HandoffPolicyEngine.swift
//  Loop (iOS)
//
//  Observes connection signals from B.2.c's PhoneWatchSessionCoordinator,
//  applies B.2.d's conservative thresholds (60s heartbeat absence, 30s
//  user-activity quiet, 10min cached-pod-state freshness), and emits
//  HandoffEvent.policyRequestedHandoff into the state machine via the
//  closure passed at init.
//
//  Parallel to LoopWatchApp's HandoffPolicyEngine — B.2.c-style two-file
//  pattern. Same logic; iOS-side coordinator is observed.
//

import Foundation
import OmniBLE
import Combine

@MainActor
protocol HandoffPolicyCoordinatorObservable: AnyObject {
    var isReachable: Bool { get }
    var lastHeartbeatReceivedAt: Date? { get }
}

extension PhoneWatchSessionCoordinator: HandoffPolicyCoordinatorObservable {}

@MainActor
final class HandoffPolicyEngine {

    static let absenceThreshold: TimeInterval = 60       // seconds
    static let userActivityQuietThreshold: TimeInterval = 30
    static let cachedPodStateMaxAge: TimeInterval = 10 * 60
    static let rebounceWindow: TimeInterval = 5

    private let coordinator: any HandoffPolicyCoordinatorObservable
    private var settings: HandoffSettings
    private let clock: () -> Date
    private let emit: (HandoffEvent) -> Void

    private var ticker: Task<Void, Never>?
    private var lastEmittedAt: Date?

    private var currentOwner: HandoffOwner = .phone
    private var phoneStableReachableSince: Date?
    private var lastUserInteractionAt: Date?
    private var cachedPodStateAt: Date?

    init(coordinator: any HandoffPolicyCoordinatorObservable,
         settings: HandoffSettings,
         clock: @escaping () -> Date = Date.init,
         emit: @escaping (HandoffEvent) -> Void) {
        self.coordinator = coordinator
        self.settings = settings
        self.clock = clock
        self.emit = emit
    }

    func start() {
        stop()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.evaluateNow() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    func updateSettings(_ new: HandoffSettings) {
        settings = new
    }

    func evaluateNow() {
        let now = clock()

        if let last = lastEmittedAt, now.timeIntervalSince(last) < Self.rebounceWindow {
            return
        }

        if let activity = lastUserInteractionAt,
           now.timeIntervalSince(activity) < Self.userActivityQuietThreshold {
            return
        }

        let cachedFreshEnough = cachedPodStateAt
            .map { now.timeIntervalSince($0) <= Self.cachedPodStateMaxAge } ?? true

        switch (currentOwner, settings.mode) {

        case (.phone, .automatic):
            // iOS perspective: phone is currently driving; we'd hand off TO watch
            // only on absence (i.e., we believe the watch is the only viable
            // driver — this is the rarer direction on iOS, but supported for
            // symmetry).
            if absenceTriggered(now: now), cachedFreshEnough {
                emit(.policyRequestedHandoff(target: .watch))
                lastEmittedAt = now
            }

        case (.watch, .automatic), (.watch, .manualWithAutoRevert):
            // iOS perspective: watch is driving; phone returns reachable + stable
            // for ≥60s → revert to phone driving.
            if let stableSince = phoneStableReachableSince,
               now.timeIntervalSince(stableSince) >= Self.absenceThreshold,
               coordinator.isReachable {
                emit(.policyRequestedHandoff(target: .phone))
                lastEmittedAt = now
            }

        default:
            return
        }
    }

    private func absenceTriggered(now: Date) -> Bool {
        guard let last = coordinator.lastHeartbeatReceivedAt else {
            return false
        }
        return now.timeIntervalSince(last) >= Self.absenceThreshold
    }

    func markCurrentOwner(_ owner: HandoffOwner) {
        currentOwner = owner
    }

    func markPhoneStableSince(_ when: Date?) {
        phoneStableReachableSince = when
    }

    func markUserInteractedAt(_ when: Date) {
        lastUserInteractionAt = when
    }

    func markCachedPodStateAge(_ when: Date) {
        cachedPodStateAt = when
    }
}
