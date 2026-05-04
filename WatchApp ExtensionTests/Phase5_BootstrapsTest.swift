//
//  Phase5_BootstrapsTest.swift
//  WatchApp Extension Tests
//
//  B.3.a Phase 5 — Smoke tests for the watch-side self-driving bootstraps:
//    * WatchAlgorithmBootstrap constructs a driver on `.watchDriver` and
//      tears it down on state change (idempotent on repeated `.watchDriver`).
//    * WatchRemoteCommandBootstrap respects the `nightscoutConfig != nil`
//      guard.
//    * BackgroundPollScheduler reschedules at the 5-minute cadence and
//      gates polling on the `shouldPoll` closure.
//

import XCTest
import LoopAlgorithmCore
import LoopKit
import LoopCore
import OmniBLE  // for HandoffState
import WatchAlgorithmKit  // for WatchAlgorithmStores, WatchSettingsSnapshot, WatchAlgorithmDriver (B.6 Phase 4a-bis)
@testable import WatchApp_Extension

@MainActor
final class Phase5_BootstrapsTest: XCTestCase {

    // MARK: - Helpers

    private func makeStores() -> WatchAlgorithmStores {
        let cacheStore = PersistenceController(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
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

    private func makeSupporting() -> WatchRemoteCommandStores {
        let cacheStore = PersistenceController(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return WatchRemoteCommandStores(
            cgmEventStore: CgmEventStore(cacheStore: cacheStore, cacheLength: .hours(24)),
            settingsStore: SettingsStore(store: cacheStore, expireAfter: .hours(24)),
            overrideHistory: TemporaryScheduleOverrideHistory(),
            insulinDeliveryStore: InsulinDeliveryStore(
                cacheStore: cacheStore,
                cacheLength: .hours(24),
                provenanceIdentifier: "test"
            )
        )
    }

    // MARK: - WatchAlgorithmBootstrap

    func testWatchAlgorithmBootstrapConstructsDriverOnWatchDriverState() {
        let stores = makeStores()
        let settings = WatchSettingsSnapshot()
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            settingsProvider: { settings }
        )
        XCTAssertNil(bootstrap.driver, "driver should not exist before any state update")

        bootstrap.update(handoffState: .watchDriver)
        XCTAssertNotNil(bootstrap.driver, "driver should be constructed on .watchDriver")
    }

    func testWatchAlgorithmBootstrapTearsDownDriverOnStateChange() {
        let stores = makeStores()
        let settings = WatchSettingsSnapshot()
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            settingsProvider: { settings }
        )
        bootstrap.update(handoffState: .watchDriver)
        XCTAssertNotNil(bootstrap.driver)

        bootstrap.update(handoffState: .phoneDriver)
        XCTAssertNil(bootstrap.driver, "driver should be torn down when leaving .watchDriver")

        // Re-entering .watchDriver should reconstruct the driver.
        bootstrap.update(handoffState: .watchDriver)
        XCTAssertNotNil(bootstrap.driver)

        // Idempotent: a repeated .watchDriver should not rebuild.
        let driverBefore = bootstrap.driver
        bootstrap.update(handoffState: .watchDriver)
        XCTAssertTrue(bootstrap.driver === driverBefore,
                      "driver should not be rebuilt on a repeated .watchDriver state")
    }

    // MARK: - WatchRemoteCommandBootstrap

    func testWatchRemoteCommandBootstrapDoesNotStartWhenNightscoutConfigIsNil() {
        let stores = makeStores()
        let supporting = makeSupporting()
        let settings = WatchSettingsSnapshot(nightscoutConfig: nil)
        let bootstrap = WatchRemoteCommandBootstrap(
            storesProvider: { stores },
            supportingStoresProvider: { supporting },
            settingsProvider: { settings }
        )
        bootstrap.update(handoffState: .watchDriver)
        XCTAssertNil(bootstrap.manager,
                     "manager should remain nil when nightscoutConfig is nil")
        XCTAssertNil(bootstrap.nightscoutService)
    }

    func testWatchRemoteCommandBootstrapTearsDownOnNonDriverState() {
        // Sanity: even when Nightscout is unconfigured (so manager never
        // starts), repeated state updates must not crash, and any non-driver
        // state must leave manager == nil.
        let stores = makeStores()
        let supporting = makeSupporting()
        let settings = WatchSettingsSnapshot(nightscoutConfig: nil)
        let bootstrap = WatchRemoteCommandBootstrap(
            storesProvider: { stores },
            supportingStoresProvider: { supporting },
            settingsProvider: { settings }
        )
        bootstrap.update(handoffState: .watchDriver)
        bootstrap.update(handoffState: .phoneDriver)
        bootstrap.update(handoffState: .recovering(reason: .timeoutWaitingForConfirmation, lastKnownOwner: .watch))
        XCTAssertNil(bootstrap.manager)
        XCTAssertNil(bootstrap.nightscoutService)
    }

    // MARK: - BackgroundPollScheduler

    func testBackgroundPollSchedulerSchedulesAtFiveMinuteCadence() {
        let recorder = RecordingScheduler()
        let scheduler = BackgroundPollScheduler(
            cadence: BackgroundPollScheduler.defaultCadence,
            shouldPoll: { false },
            performPoll: {},
            scheduler: recorder
        )
        scheduler.scheduleNext()
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(BackgroundPollScheduler.defaultCadence, 5 * 60)
    }

    func testBackgroundPollSchedulerHandleWakeGatesOnShouldPoll() {
        var pollCount = 0
        let recorder = RecordingScheduler()

        // shouldPoll == false: wake should reschedule but not poll.
        let blockedScheduler = BackgroundPollScheduler(
            shouldPoll: { false },
            performPoll: { pollCount += 1 },
            scheduler: recorder
        )
        blockedScheduler.handleWake()
        XCTAssertEqual(pollCount, 0, "shouldPoll==false must not invoke performPoll")
        XCTAssertEqual(recorder.scheduleCount, 1, "handleWake should still reschedule")

        // shouldPoll == true: wake should poll and reschedule.
        let activeScheduler = BackgroundPollScheduler(
            shouldPoll: { true },
            performPoll: { pollCount += 1 },
            scheduler: recorder
        )
        activeScheduler.handleWake()
        XCTAssertEqual(pollCount, 1, "shouldPoll==true must invoke performPoll once")
        XCTAssertEqual(recorder.scheduleCount, 2)
    }
}

// MARK: - Test scheduler

private final class RecordingScheduler: BackgroundRefreshScheduling {
    var scheduleCount = 0
    var lastDate: Date?

    func scheduleBackgroundRefresh(withPreferredDate date: Date,
                                   userInfo: (NSSecureCoding & NSObjectProtocol)?,
                                   scheduledCompletion: @escaping (Error?) -> Void) {
        scheduleCount += 1
        lastDate = date
        scheduledCompletion(nil)
    }
}
