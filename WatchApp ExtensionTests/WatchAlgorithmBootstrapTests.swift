//
//  WatchAlgorithmBootstrapTests.swift
//  WatchApp ExtensionTests
//
//  B.8.3 Phase 3 — Verify the bootstrap's settings-publisher subscription
//  + retryIfNeeded() gating logic.
//
//  Three scenarios:
//    1. Idempotency: repeated `.watchDriver` updates don't rebuild the driver.
//    2. Disk-hydration bootstrap: a cold-start cache (pre-populated UserDefaults)
//       feeds the bootstrap's syncProvider so it can construct a driver without
//       waiting for a fresh phone sync.
//    3. Reentry no-op: once the driver is alive, a subsequent settings emission
//       on the publisher does NOT rebuild the driver (startIfNeeded short-circuit).
//

import XCTest
import Combine
import LoopAlgorithmCore
import LoopKit
import LoopCore
import OmniBLE  // PhoneWatchSettingsSync, HandoffState
import WatchAlgorithmKit  // WatchAlgorithmStores, WatchSettingsSnapshot
@testable import WatchApp_Extension

final class WatchAlgorithmBootstrapTests: XCTestCase {

    // MARK: - Helpers

    private var isolatedSuiteNames: [String] = []

    private func isolatedDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "B8.3.bootstrap.\(testName).\(UUID().uuidString)"
        isolatedSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    override func setUp() {
        super.setUp()
        // Reset the singleton between tests so tests #1/#2 don't see stale
        // state from a prior run, and so test #3's cache.update() emission
        // path is observable on a clean baseline.
        WatchSettingsCache.shared.resetForTesting()
    }

    override func tearDown() {
        for suiteName in isolatedSuiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        isolatedSuiteNames.removeAll()
        WatchSettingsCache.shared.resetForTesting()
        super.tearDown()
    }

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

    /// Inline fixture — mirrors the `sampleSync` shape from
    /// Phase6_SettingsSyncReceptionTests. `maximumBolus` parameter lets a test
    /// produce a not-equal payload (so the cache's dedup guard doesn't drop
    /// the second update).
    private func makeSampleSync(maximumBolus: Double = 12.0) -> PhoneWatchSettingsSync {
        PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 0.8),
                RepeatingScheduleValue(startTime: 21600, value: 1.0)
            ],
            insulinSensitivityScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 50.0)
            ],
            carbRatioScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 10.0)
            ],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: maximumBolus,
            maximumBasalRatePerHourUnits: 3.5,
            suspendThresholdMgdL: 72.0,
            nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
                url: URL(string: "https://example-ns.test")!,
                apiSecret: "secret-abc"
            )
        )
    }

    // MARK: - Tests

    /// Re-entering `.watchDriver` after a driver is already alive must not
    /// rebuild it (preserves the existing idempotency invariant).
    func testStartIfNeededIsIdempotent() {
        let stores = makeStores()
        let sync = makeSampleSync()
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            syncProvider: { sync }
        )

        bootstrap.update(handoffState: .watchDriver)
        let firstDriver = bootstrap.driver
        XCTAssertNotNil(firstDriver, "Driver should be set after first update(.watchDriver)")

        bootstrap.update(handoffState: .watchDriver)
        XCTAssertTrue(bootstrap.driver === firstDriver,
                      "Re-entering .watchDriver should not rebuild driver (identity equal)")
    }

    /// Cold-start path: nothing has arrived from the phone in this session,
    /// but the App Group UserDefaults already has a last-good payload from a
    /// prior session. The bootstrap should construct its driver using the
    /// disk-hydrated payload (no fresh phone sync needed).
    func testBootstrapsFromPersistedSettingsOnLaunch() {
        let testDefaults = isolatedDefaults()
        let fixture = makeSampleSync()
        testDefaults.set(codable: fixture, forKey: "WatchSettingsCache.lastGood")

        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)
        XCTAssertEqual(cache.current, fixture,
                       "Cache should hydrate current from persisted lastGood on init")

        let stores = makeStores()
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            syncProvider: { cache.current }
        )

        bootstrap.update(handoffState: .watchDriver)

        XCTAssertNotNil(bootstrap.driver,
                        "Bootstrap should start using disk-persisted settings (no fresh sync arrived)")
    }

    /// Once the driver is alive, a subsequent settings-publisher emission
    /// must NOT rebuild the driver. The `startIfNeeded()` early-return on
    /// `driver != nil` short-circuits the retry path even though the
    /// publisher fired.
    func testReentryAfterDriverAliveIsNoOp() {
        let stores = makeStores()
        let cache = WatchSettingsCache.shared

        // Seed the singleton so the bootstrap's syncProvider has a value
        // when `.watchDriver` is delivered.
        cache.update(makeSampleSync())

        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { stores },
            syncProvider: { cache.current }
        )

        bootstrap.update(handoffState: .watchDriver)
        let originalDriver = bootstrap.driver
        XCTAssertNotNil(originalDriver, "Driver should be alive after first watchDriver entry")

        // A different payload triggers the publisher (dedup guard passes).
        // Subscription is on shared.publisher → retryIfNeeded() → startIfNeeded()
        // → early-return because driver != nil.
        cache.update(makeSampleSync(maximumBolus: 7.5))

        // Allow the Combine sink to drain on the main queue.
        let exp = expectation(description: "main-queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(bootstrap.driver === originalDriver,
                      "Settings update after driver alive should not rebuild")
    }
}
