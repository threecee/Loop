//
//  ShadowStateScheduler.swift
//  LoopWatchApp (watchOS)
//
//  Periodic + change-driven trigger for shadow-state proactive shipping.
//  Fires `fire` closure every `interval` seconds while running, plus
//  immediately on `notifyPodStateChanged()`. The orchestrator's fire closure
//  emits HandoffEvent.shadowStateRefreshDue into the state machine.
//

import Foundation

@MainActor
final class ShadowStateScheduler {

    static let defaultInterval: TimeInterval = 5 * 60   // 5 min

    private let interval: TimeInterval
    private let clock: () -> Date
    private var fire: () -> Void

    private var task: Task<Void, Never>?

    init(interval: TimeInterval = ShadowStateScheduler.defaultInterval,
         clock: @escaping () -> Date = Date.init,
         fire: @escaping () -> Void) {
        self.interval = interval
        self.clock = clock
        self.fire = fire
    }

    func setFire(_ newFire: @escaping () -> Void) {
        fire = newFire
    }

    func start() {
        stop()
        task = Task { [weak self, interval] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run { self.fire() }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func notifyPodStateChanged() {
        fire()
    }
}
