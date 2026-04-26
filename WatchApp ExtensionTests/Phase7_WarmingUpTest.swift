//
//  Phase7_WarmingUpTest.swift
//  WatchApp ExtensionTests
//
//  B.3.a Phase 7 — Tests for the watch warm-up badge:
//    * WatchAlgorithmDriver.isWarmingUp starts as true.
//    * isWarmingUp transitions to false after loopAlgorithmRunnerDidFinishLoop.
//    * warmUpDidCompleteNotification is posted exactly once on first finish.
//    * WatchAlgorithmBootstrap.driver.isWarmingUp is initially true
//      immediately after handoff to .watchDriver.
//

import XCTest
import LoopAlgorithmCore
import LoopKit
import LoopCore
import OmniBLE  // for HandoffState
@testable import WatchApp_Extension

final class Phase7_WarmingUpTest: XCTestCase {

    // MARK: - Helpers

    private func makeStores() -> WatchAlgorithmStores {
        let cacheStore = PersistenceController(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let carbStore = CarbStore(
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            defaultAbsorptionTimes: LoopCoreConstants.defaultCarbAbsorptionTimes,
            syncVersion: 0,
            provenanceIdentifier: "test"
        )
        let glucoseStore = GlucoseStore(
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            provenanceIdentifier: "test"
        )
        let doseStore = DoseStore(
            cacheStore: cacheStore,
            cacheLength: .hours(24),
            insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
            longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
            basalProfile: nil,
            insulinSensitivitySchedule: nil,
            overrideHistory: nil,
            lastPumpEventsReconciliation: nil,
            provenanceIdentifier: "test"
        )
        let ddStore = DosingDecisionStore(store: cacheStore, expireAfter: .hours(24))
        return WatchAlgorithmStores(
            carbStore: carbStore,
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            dosingDecisionStore: ddStore
        )
    }

    private func makeDriver() -> WatchAlgorithmDriver {
        let stores = makeStores()
        let settings = WatchSettingsSnapshot()
        return WatchAlgorithmDriver(
            carbStore: stores.carbStore,
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            dosingDecisionStore: stores.dosingDecisionStore,
            settingsSnapshot: settings
        )
    }

    // MARK: - isWarmingUp initial state

    func testIsWarmingUpInitiallyTrue() {
        let driver = makeDriver()
        XCTAssertTrue(driver.isWarmingUp,
                      "isWarmingUp must be true immediately after construction")
    }

    // MARK: - isWarmingUp clears after first iteration

    func testIsWarmingUpFalseAfterFirstLoopIteration() {
        let driver = makeDriver()
        XCTAssertTrue(driver.isWarmingUp)

        // Simulate the runner's delegate callback via the LoopAlgorithmRunnerDelegate
        // conformance on the driver (internal access via @testable import).
        // We drive the callback directly rather than running the full algorithm
        // so the test is fast and deterministic.
        let expectation = expectation(description: "isWarmingUp transitions to false")
        let cancellable = driver.$isWarmingUp.dropFirst().sink { isWarmingUp in
            if !isWarmingUp {
                expectation.fulfill()
            }
        }

        // Trigger the first iteration completion via the delegate method.
        driver.loopAlgorithmRunnerDidFinishLoop(driver.underlyingRunner)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(driver.isWarmingUp,
                       "isWarmingUp must be false after first loopAlgorithmRunnerDidFinishLoop")
        _ = cancellable
    }

    // MARK: - Notification is posted exactly once

    func testWarmUpNotificationPostedOnceOnFirstIteration() {
        let driver = makeDriver()
        var notificationCount = 0

        let observer = NotificationCenter.default.addObserver(
            forName: WatchAlgorithmDriver.warmUpDidCompleteNotification,
            object: driver,
            queue: .main
        ) { _ in
            notificationCount += 1
        }

        // First finish: should post the notification.
        let expectation = expectation(description: "warmUpDidComplete notification received")
        let cancellable = driver.$isWarmingUp.dropFirst().sink { _ in
            expectation.fulfill()
        }
        driver.loopAlgorithmRunnerDidFinishLoop(driver.underlyingRunner)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(notificationCount, 1,
                       "warmUpDidCompleteNotification should be posted exactly once")

        // Second finish: should NOT post the notification again.
        driver.loopAlgorithmRunnerDidFinishLoop(driver.underlyingRunner)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(notificationCount, 1,
                       "warmUpDidCompleteNotification must not be posted on subsequent iterations")

        NotificationCenter.default.removeObserver(observer)
        _ = cancellable
    }

    // MARK: - Bootstrap driver starts warming up

    func testBootstrapDriverIsWarmingUpOnWatchDriverState() {
        let stores = makeStores()
        let settings = WatchSettingsSnapshot()
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            settingsProvider: { settings }
        )
        bootstrap.update(handoffState: .watchDriver)

        XCTAssertNotNil(bootstrap.driver, "driver must exist after .watchDriver")
        XCTAssertTrue(bootstrap.driver?.isWarmingUp == true,
                      "driver.isWarmingUp must be true immediately after handoff")
    }
}
