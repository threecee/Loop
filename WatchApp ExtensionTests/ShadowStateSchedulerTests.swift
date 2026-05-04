//
//  ShadowStateSchedulerTests.swift
//  LoopWatchApp Watch AppTests
//

import XCTest
import OmniBLE
@testable import WatchApp_Extension

@MainActor
final class ShadowStateSchedulerTests: XCTestCase {

    private var firedCount: Int = 0
    private var clock: Date!

    override func setUp() async throws {
        firedCount = 0
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeScheduler(intervalSeconds: TimeInterval = 0.5) -> ShadowStateScheduler {
        ShadowStateScheduler(
            role: .watch,
            interval: intervalSeconds,
            clock: { [unowned self] in self.clock },
            fire: { [unowned self] in self.firedCount += 1 }
        )
    }

    func testStartTriggersPeriodicFiring() async throws {
        let scheduler = makeScheduler(intervalSeconds: 0.3)
        scheduler.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(firedCount, 2)
    }

    func testStopHaltsFiring() async throws {
        let scheduler = makeScheduler(intervalSeconds: 0.3)
        scheduler.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        scheduler.stop()
        let countAtStop = firedCount
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(firedCount, countAtStop)
    }

    func testNotifyChangedTriggersImmediateFire() {
        let scheduler = makeScheduler()
        scheduler.notifyPodStateChanged()
        XCTAssertEqual(firedCount, 1)
    }

    func testRestartAfterStopWorks() async throws {
        let scheduler = makeScheduler(intervalSeconds: 0.2)
        scheduler.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        scheduler.stop()
        let firstRunCount = firedCount
        scheduler.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        scheduler.stop()
        XCTAssertGreaterThan(firedCount, firstRunCount)
    }
}
