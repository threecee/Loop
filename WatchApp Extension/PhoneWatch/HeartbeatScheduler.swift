//
//  HeartbeatScheduler.swift
//  LoopWatchApp (watchOS)
//
//  Fires a closure every `interval` seconds while running. Task-based on
//  watchOS (cleaner than Timer at this scale, better cancellation story).
//

import Foundation

final class HeartbeatScheduler {
    private let interval: TimeInterval
    private let fire: () -> Void
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, fire: @escaping () -> Void) {
        self.interval = interval
        self.fire = fire
    }

    func start() {
        stop()
        task = Task { [interval, fire] in
            while !Task.isCancelled {
                fire()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
