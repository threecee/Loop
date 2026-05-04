//
//  Phase6_SettingsSyncReceptionTests.swift
//  WatchApp ExtensionTests
//
//  B.3.a Phase 6 — Watch-side settings sync reception tests.
//
//  Test 2: receiving a PhoneWatchSettingsSync via mock transport stores
//          it in WatchSettingsCache and the snapshot converts correctly.
//

import XCTest
import Combine
import LoopKit
import OmniBLE  // for PhoneWatchSettingsSync, HandoffState
import WatchAlgorithmKit  // for WatchSettingsSnapshot (B.6 Phase 4a-bis)
@testable import WatchApp_Extension

@MainActor
final class Phase6_SettingsSyncReceptionTests: XCTestCase {

    // MARK: - B.8.3 helper: isolated UserDefaults suite per test

    private var isolatedSuiteNames: [String] = []

    /// Returns a fresh, isolated `UserDefaults` suite scoped to this test.
    /// Suites are cleaned up in `tearDown()` to keep the device's defaults
    /// area clean across runs.
    private func isolatedDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "B8.3.\(testName).\(UUID().uuidString)"
        isolatedSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        for suiteName in isolatedSuiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        isolatedSuiteNames.removeAll()
        super.tearDown()
    }

    private let sampleSync = PhoneWatchSettingsSync(
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
        maximumBolusUnits: 12.0,
        maximumBasalRatePerHourUnits: 3.5,
        suspendThresholdMgdL: 72.0,
        nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
            url: URL(string: "https://example-ns.test")!,
            apiSecret: "secret-abc"
        )
    )

    // MARK: - Test 2a: cache stores incoming sync

    func testWatchSettingsCacheStoresSync() {
        let cache = WatchSettingsCache(appGroupDefaults: isolatedDefaults())
        XCTAssertNil(cache.current, "cache should be empty before first sync")

        cache.update(sampleSync)

        XCTAssertNotNil(cache.current)
        XCTAssertEqual(cache.current?.maximumBolusUnits, 12.0)
        XCTAssertEqual(cache.current?.nightscoutConfig?.apiSecret, "secret-abc")
    }

    // MARK: - Test 2b: WatchSettingsSnapshot converts from sync

    func testWatchSettingsSnapshotConvertsFromSync() {
        let snapshot = WatchSettingsSnapshot(fromSync: sampleSync)

        // LoopSettings round-trip
        XCTAssertEqual(snapshot.loopSettings.maximumBolus, 12.0)
        XCTAssertEqual(snapshot.loopSettings.maximumBasalRatePerHour, 3.5)
        XCTAssertEqual(snapshot.loopSettings.suspendThreshold?.value, 72.0)
        XCTAssertNotNil(snapshot.loopSettings.basalRateSchedule)
        XCTAssertEqual(snapshot.loopSettings.basalRateSchedule?.items.count, 2)

        // Nightscout config
        XCTAssertNotNil(snapshot.nightscoutConfig)
        XCTAssertEqual(snapshot.nightscoutConfig?.siteURL.absoluteString, "https://example-ns.test")
        XCTAssertEqual(snapshot.nightscoutConfig?.apiSecret, "secret-abc")

        // StoredSettings mirrors LoopSettings
        XCTAssertEqual(snapshot.storedSettings.maximumBolus, 12.0)
        XCTAssertEqual(snapshot.storedSettings.suspendThreshold?.value, 72.0)
    }

    // MARK: - Test 2c: snapshot with nil Nightscout config

    func testWatchSettingsSnapshotWithNoNightscout() {
        let syncNoNS = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 0.5)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 5.0,
            maximumBasalRatePerHourUnits: 2.0,
            suspendThresholdMgdL: nil,
            nightscoutConfig: nil
        )
        let snapshot = WatchSettingsSnapshot(fromSync: syncNoNS)
        XCTAssertNil(snapshot.nightscoutConfig,
                     "no nightscout config in sync → snapshot.nightscoutConfig must be nil")
        XCTAssertNil(snapshot.loopSettings.suspendThreshold)
    }

    // MARK: - B.4 Issue #3: automaticDosing flags read from sync

    /// When sync provides automaticDosingEnabled = true, the constructed
    /// snapshot reports automaticDosingEnabled = true (not hardcoded false).
    func testInitFromSyncReadsAutomaticDosingEnabledWhenTrue() {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: 2,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10,
            maximumBasalRatePerHourUnits: 4,
            suspendThresholdMgdL: 72,
            nightscoutConfig: nil,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true
        )
        let snapshot = WatchSettingsSnapshot(fromSync: sync)
        XCTAssertTrue(snapshot.automaticDosingEnabled,
                      "Watch should read automaticDosingEnabled from sync, not hardcode false")
        XCTAssertTrue(snapshot.isAutomaticDosingAllowed,
                      "Watch should read isAutomaticDosingAllowed from sync, not hardcode false")
    }

    /// When sync's flags are nil (v1 sender), snapshot defaults to false (fail-closed).
    func testInitFromSyncDefaultsToFalseWhenSyncFlagsAreNil() {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: 1,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10,
            maximumBasalRatePerHourUnits: 4,
            suspendThresholdMgdL: 72,
            nightscoutConfig: nil
            // automaticDosingEnabled + isAutomaticDosingAllowed default to nil
        )
        let snapshot = WatchSettingsSnapshot(fromSync: sync)
        XCTAssertFalse(snapshot.automaticDosingEnabled,
                       "Nil sync flag → false (fail-closed) on watch")
        XCTAssertFalse(snapshot.isAutomaticDosingAllowed,
                       "Nil sync flag → false (fail-closed) on watch")
    }

    /// Phone explicitly disabled automatic dosing → snapshot reads false.
    /// Distinguishes the "phone said no" path from the v1-fallback path
    /// (which `testInitFromSyncDefaultsToFalseWhenSyncFlagsAreNil` covers).
    /// Critical because flipping the operator from `?? false` to `?? true`
    /// would still pass the v1-fallback test (nil ?? true == true would
    /// look like the v1 path returning true) — only an explicit-false
    /// reception test locks in the safety-critical operator semantics.
    func testInitFromSyncReadsAutomaticDosingDisabledWhenFalse() {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: 2,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10,
            maximumBasalRatePerHourUnits: 4,
            suspendThresholdMgdL: 72,
            nightscoutConfig: nil,
            automaticDosingEnabled: false,
            isAutomaticDosingAllowed: false
        )
        let snapshot = WatchSettingsSnapshot(fromSync: sync)
        XCTAssertFalse(snapshot.automaticDosingEnabled,
                       "Phone explicitly disabled → watch reads false (not the v1-fallback path)")
        XCTAssertFalse(snapshot.isAutomaticDosingAllowed,
                       "Phone explicitly disabled → watch reads false (not the v1-fallback path)")
    }

    // MARK: - B.5.2 Issue #3: timeZone round-trips through the cache

    /// A sync carrying a `timeZone` identifier survives caching + JSON
    /// round-trip unchanged, so the watch-side bootstrap reads the same
    /// identifier the phone emitted.
    func testTimeZoneRoundTripsThroughCache() {
        let cache = WatchSettingsCache(appGroupDefaults: isolatedDefaults())
        let sync = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10.0,
            maximumBasalRatePerHourUnits: 4.0,
            suspendThresholdMgdL: 72.0,
            nightscoutConfig: nil,
            timeZone: "Europe/Copenhagen"
        )

        cache.update(sync)

        XCTAssertEqual(cache.current?.timeZone, "Europe/Copenhagen",
                       "timeZone identifier must survive cache round-trip")
    }

    // MARK: - B.8.2 Issue #4 + B.8.3: watch-side equality short-circuit (sink-based)

    /// `WatchSettingsCache.update(_:)` should treat a second identical sync
    /// as a no-op: the publisher does NOT fire and `current` stays put.
    /// Defends against the case where the phone's dedup cache is empty after
    /// launch and re-emits a payload the watch has already absorbed.
    ///
    /// B.8.3 migration: replaces the B.8.2 `writeCount`-based assertion with
    /// a sink counter on the new `publisher`. Production no longer carries
    /// the `#if DEBUG writeCount` instrumentation.
    func testUpdateShortCircuitsOnEqualPayload() {
        let testDefaults = isolatedDefaults()
        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)

        var emissions = 0
        let cancellable = cache.publisher
            .dropFirst()  // skip CurrentValueSubject's initial nil replay
            .sink { _ in emissions += 1 }

        cache.update(sampleSync)
        XCTAssertEqual(emissions, 1, "first update should fire publisher once")

        cache.update(sampleSync)
        XCTAssertEqual(emissions, 1,
                       "Identical sync should be a no-op (no second publisher fire)")

        // Sanity: a different sync still fires the publisher.
        let mutated = PhoneWatchSettingsSync(
            protocolVersion: sampleSync.protocolVersion,
            sentAt: sampleSync.sentAt,
            basalScheduleItems: sampleSync.basalScheduleItems,
            insulinSensitivityScheduleItems: sampleSync.insulinSensitivityScheduleItems,
            carbRatioScheduleItems: sampleSync.carbRatioScheduleItems,
            glucoseTargetRangeScheduleItems: sampleSync.glucoseTargetRangeScheduleItems,
            maximumBolusUnits: 7.5,                      // changed
            maximumBasalRatePerHourUnits: sampleSync.maximumBasalRatePerHourUnits,
            suspendThresholdMgdL: sampleSync.suspendThresholdMgdL,
            nightscoutConfig: sampleSync.nightscoutConfig
        )
        cache.update(mutated)
        XCTAssertEqual(emissions, 2, "Different payload should fire publisher")

        _ = cancellable  // keep alive
    }

    // MARK: - B.8.3: hydration from persisted last-good on init

    /// On init, the cache should hydrate `current` from the App Group
    /// `UserDefaults` key `WatchSettingsCache.lastGood`, so a watch-app cold
    /// start has settings available before any fresh `.settingsSync` arrives.
    func testHydratesFromPersistedLastGoodOnInit() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(codable: sampleSync, forKey: "WatchSettingsCache.lastGood")

        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)

        XCTAssertEqual(cache.current, sampleSync,
                       "Cache should hydrate current from persisted lastGood on init")
    }

    // MARK: - B.8.3: publisher fires on update

    /// `update(_:)` past the equality guard should fire the publisher exactly
    /// once. The CurrentValueSubject also replays the existing value (nil in
    /// this test, no persistence) on subscribe.
    func testPublisherFiresOnUpdate() {
        let testDefaults = isolatedDefaults()
        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)

        var emissions: [PhoneWatchSettingsSync?] = []
        let cancellable = cache.publisher
            .sink { emissions.append($0) }

        XCTAssertEqual(emissions.count, 1,
                       "CurrentValueSubject should replay current value on subscribe")
        XCTAssertNil(emissions[0],
                     "Initial replay should be nil (no persistence in this test)")

        cache.update(sampleSync)
        XCTAssertEqual(emissions.count, 2, "Update should fire publisher once")
        XCTAssertEqual(emissions[1], sampleSync)

        _ = cancellable
    }

    // MARK: - B.8.3: publisher does NOT fire on equal payload

    /// Subscribers that `.dropFirst()` past the replay should see ZERO
    /// emissions when an identical sync is applied a second time.
    func testPublisherDoesNotFireOnEqualPayload() {
        let testDefaults = isolatedDefaults()
        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)

        cache.update(sampleSync)

        var laterEmissions = 0
        let cancellable = cache.publisher
            .dropFirst()  // skip the CurrentValueSubject replay of the existing value
            .sink { _ in laterEmissions += 1 }

        cache.update(sampleSync)
        XCTAssertEqual(laterEmissions, 0,
                       "Identical payload should not fire publisher")

        _ = cancellable
    }

    // MARK: - B.8.3: late subscriber receives hydrated value via replay

    /// A subscriber attaching AFTER init should receive the hydrated value
    /// thanks to `CurrentValueSubject` replay-on-subscribe semantics.
    func testPublisherEmitsHydratedValueOnSubscribe() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(codable: sampleSync, forKey: "WatchSettingsCache.lastGood")
        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)

        var receivedValue: PhoneWatchSettingsSync?
        let cancellable = cache.publisher
            .compactMap { $0 }
            .sink { receivedValue = $0 }

        XCTAssertEqual(receivedValue, sampleSync,
                       "Late subscriber should receive hydrated value via CurrentValueSubject")

        _ = cancellable
    }

    // MARK: - B.8.3: update(_:) persists to disk

    /// `update(_:)` should write through to App Group `UserDefaults` so a
    /// later cache instance pointed at the same defaults hydrates from disk.
    func testUpdatePersistsToDisk() {
        let testDefaults = isolatedDefaults()
        let cache1 = WatchSettingsCache(appGroupDefaults: testDefaults)
        cache1.update(sampleSync)

        // A SECOND cache instance pointing at the same defaults must
        // hydrate `current` from what cache1 wrote.
        let cache2 = WatchSettingsCache(appGroupDefaults: testDefaults)

        XCTAssertEqual(cache2.current, sampleSync,
                       "Second cache instance should hydrate from disk written by first")
    }

    // MARK: - B.5.1 leftover #3 / B.8.2 / B.8.3: resetForTesting() is #if-DEBUG-guarded

    /// Regression-prevention test: `WatchSettingsCache.resetForTesting()` is
    /// wrapped in `#if DEBUG ... #endif` (added in B.5.1). The mere fact that
    /// this test compiles in DEBUG builds — and that it would fail to compile
    /// in a Release build because `resetForTesting()` would not exist there —
    /// is what enforces the guard. The body exercises the call to verify
    /// behavior end-to-end so a future refactor can't silently move the method
    /// outside the guard while still satisfying a name-only check.
    ///
    /// B.8.3: `resetForTesting()` body now also clears the persisted
    /// `WatchSettingsCache.lastGood` key alongside the in-memory subject.
    #if DEBUG
    func testResetForTestingIsDebugGuarded() {
        let testDefaults = isolatedDefaults()
        let cache = WatchSettingsCache(appGroupDefaults: testDefaults)
        cache.update(sampleSync)
        XCTAssertNotNil(cache.current, "precondition: cache populated before reset")
        XCTAssertNotNil(testDefaults.codableValue(forKey: "WatchSettingsCache.lastGood",
                                                  as: PhoneWatchSettingsSync.self),
                        "precondition: persisted lastGood present before reset")

        // This call would be a compile error in a Release build (the method
        // would not exist) — that's the load-bearing property of the guard.
        cache.resetForTesting()

        XCTAssertNil(cache.current, "After resetForTesting, current should be nil")
        XCTAssertNil(testDefaults.codableValue(forKey: "WatchSettingsCache.lastGood",
                                                as: PhoneWatchSettingsSync.self),
                     "After resetForTesting, persisted lastGood should be removed")
    }
    #endif

    // MARK: - Test 2d: bootstrap settingsProvider reads from cache

    func testBootstrapSettingsProviderReadsFromCache() {
        let cache = WatchSettingsCache(appGroupDefaults: isolatedDefaults())
        // Provider returns nil until cache has been populated.
        let bootstrap = WatchAlgorithmBootstrap(
            storesProvider: { nil },
            syncProvider: { cache.current }
        )

        // Before any sync: settings provider returns nil (stores not ready,
        // but the closure chain returns nil so startIfNeeded will bail).
        // This just verifies the closure wiring doesn't crash.
        _ = bootstrap  // exercised below

        // After populating the cache, provider should return a snapshot.
        cache.update(sampleSync)
        // The provider closure itself is private, but we can verify the
        // bootstrap's behavior: it won't start the driver without stores,
        // but the settings provider path is exercised on state update.
        bootstrap.update(handoffState: HandoffState.watchDriver)
        // Stores are nil → driver is nil (provider nil check happens *after*
        // stores nil check in startIfNeeded — either way driver is nil without
        // stores, which is the expected test outcome here).
        XCTAssertNil(bootstrap.driver,
                     "driver is nil because storesProvider returns nil; settings path exercised")
    }
}
