//
//  WatchAlgorithmEndToEndTests.swift
//  WatchApp ExtensionTests
//
//  B.8 Phase 3 — end-to-end snapshot-flow scenarios for the watch algorithm
//  driver. Verifies the seam between WarmUpDecider's verdict and the
//  driver's runtime suppression behavior on the FIRST iteration:
//
//    * `.skipWarmup(snapshot:)`  → driver.isWarmingUp == false → first
//      didRecommend does NOT record a `.warmingUp` suppression (the snapshot
//      path is what B.8 introduces).
//    * `.fullWarmup(failedGate:)` → driver.isWarmingUp == true → first
//      didRecommend DOES record a `.warmingUp` suppression (today's
//      pre-B.8 fallback behavior, preserved verbatim).
//
//  The init-time isWarmingUp derivation is unit-tested in
//  WatchAlgorithmDriverTests.test_init_skipsWarmupWhenDecisionSaysSkip /
//  test_init_isWarmingUpWhenDecisionSaysFullWarmup. These tests go further
//  by driving an actual recommendation through the didRecommend delegate
//  hook and inspecting the dosing-decision store, which is the seam that
//  matters for the iOS event log.
//
//  Modeled on Phase7_WarmingUpTest.swift (lightweight in-process driver
//  construction, no PodSimulator) plus the RecordingDecisionStore /
//  recommendation-driving idiom from WatchAlgorithmDriverTests.swift.
//
//  The heavyweight PodSimulator-backed end-to-end test (algorithm runs
//  against an emulated pod) lives at
//  OmniBLETests/Integration/WatchAlgorithmEndToEndTests.swift — that one
//  cannot reach `WatchAlgorithmSnapshotCache` because the cache is wrapped
//  in `#if !os(iOS)` and not exported via WatchAlgorithmKit.
//

import XCTest
import LoopAlgorithmCore
import LoopKit
import LoopCore
import OmniBLE  // for AlgorithmStateSnapshot, PumpStatusSnapshot
import WatchAlgorithmKit  // for WatchAlgorithmDriver, WarmUpDecision, WatchDoseSuppressionReason
@testable import WatchApp_Extension  // for WatchAlgorithmSnapshotCache.shared / resetForTesting()

final class WatchAlgorithmEndToEndTests: XCTestCase {

    // MARK: - Lifecycle

    override func tearDown() {
        // Belt-and-suspenders: each test also uses `defer { resetForTesting() }`
        // but if a test fails before the defer runs (or someone forgets it on
        // a future test), this catches the leak so the next test in the suite
        // sees an empty cache.
        WatchAlgorithmSnapshotCache.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Mocks

    /// Minimal DosingDecisionStoreProtocol that records what the driver tries
    /// to persist. Mirrors the shape used by WatchAlgorithmDriverTests'
    /// `RecordingDecisionStore` (kept here as a private nested type so the two
    /// test files don't entangle).
    private final class RecordingDecisionStore: DosingDecisionStoreProtocol {
        var storedDecisions: [StoredDosingDecision] = []

        func storeDosingDecision(_ dosingDecision: StoredDosingDecision,
                                 completion: @escaping () -> Void) {
            storedDecisions.append(dosingDecision)
            completion()
        }
    }

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

    /// Builds a driver wired to the provided RecordingDecisionStore (NOT to
    /// the per-stores DosingDecisionStore) so tests can assert on what the
    /// suppression path recorded. Mirrors the construction shape used by
    /// `Phase7_WarmingUpTest.makeDriver()` plus the
    /// `WatchAlgorithmDriverTests.makeDriver(warmUpDecision:)` injection.
    ///
    /// Pump manager is intentionally `nil` and `WatchSettingsSnapshot()`'s
    /// defaults leave automaticDosing disabled — these tests assert on the
    /// warmingUp gate (gate 1) only, which evaluates BEFORE every other
    /// gate. The fresh-snapshot test exits gate 1 and is expected to fall
    /// through to a different gate (e.g., gate 2 .automaticDosingDisabled
    /// from default settings, or gate 4 .noPumpManager if those defaults
    /// were flipped); that's fine — the assertion only checks that the
    /// recorded reason is NOT `.warmingUp`. The fallback test exits at
    /// gate 1 with `.warmingUp`, which is the behavior under test.
    private func makeDriver(warmUpDecision: WarmUpDecision) -> (driver: WatchAlgorithmDriver,
                                                                store: RecordingDecisionStore) {
        let stores = makeStores()
        let store = RecordingDecisionStore()
        let settings = WatchSettingsSnapshot()
        let driver = WatchAlgorithmDriver(
            carbStore: stores.carbStore,
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            dosingDecisionStore: store,
            settingsSnapshot: settings,
            pumpManager: nil,
            isWarmingUpOverride: nil,         // Let warmUpDecision drive isWarmingUp
            warmUpDecision: warmUpDecision
        )
        return (driver, store)
    }

    private func makeFreshSnapshot(now: Date) -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now.addingTimeInterval(-30),
            phoneIterationDate: now.addingTimeInterval(-30),
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 100,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: now),
            activeOverride: nil
        )
    }

    private func sampleRecommendation()
        -> (recommendation: AutomaticDoseRecommendation, date: Date) {
        let basal = TempBasalRecommendation(unitsPerHour: 1.5, duration: 30 * 60)
        let rec = AutomaticDoseRecommendation(basalAdjustment: basal, bolusUnits: 0.0)
        return (rec, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Tests

    /// B.8: when the snapshot cache contains a fresh snapshot and the
    /// WarmUpDecider would return `.skipWarmup`, the driver bypasses the
    /// warming-up gate and the FIRST iteration's recommendation does NOT get
    /// suppressed with a `.warmingUp` reason. (It will be suppressed for
    /// `.noPumpManager` because this lightweight harness has no pump — the
    /// assertion is specifically that the warmingUp reason did not fire.)
    func test_b8_freshSnapshot_firstIterationDoesNotSuppressWithWarmingUp() {
        let now = Date()
        let snapshot = makeFreshSnapshot(now: now)

        // Production write path: the bootstrap reads the cache, then asks
        // the decider, then constructs the driver. We exercise the cache
        // write to keep the test honest about what production does, even
        // though the test injects the resulting WarmUpDecision directly.
        WatchAlgorithmSnapshotCache.shared.update(snapshot)
        defer { WatchAlgorithmSnapshotCache.shared.resetForTesting() }

        let (driver, store) = makeDriver(warmUpDecision: .skipWarmup(snapshot: snapshot))
        XCTAssertFalse(driver.isWarmingUp,
                       ".skipWarmup must drive isWarmingUp to false at init")

        // Drive a recommendation through the didRecommend delegate hook —
        // same idiom as WatchAlgorithmDriverTests' suppression tests.
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(driver.underlyingRunner,
                                    didRecommend: (rec, date)) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        // The warmingUp gate (gate 1) must NOT have fired. A different gate
        // (here, .noPumpManager — gate 4) may have suppressed because this
        // lightweight harness has no pump; that's fine — the snapshot path's
        // contract is "skip the warmup-window suppression," not "guarantee
        // a dose enacts."
        let warmingUpRecorded = store.storedDecisions.contains { decision in
            decision.reason == WatchDoseSuppressionReason.warmingUp.rawValue
        }
        XCTAssertFalse(
            warmingUpRecorded,
            "Snapshot-fresh path must NOT suppress with warmingUp reason; recorded reasons: \(store.storedDecisions.map { $0.reason ?? "<nil>" })"
        )
    }

    /// B.8: when no snapshot is cached (or when WarmUpDecider would otherwise
    /// return `.fullWarmup`), the driver retains today's pre-B.8 behavior:
    /// `isWarmingUp` is true at init, and the FIRST iteration's
    /// recommendation IS suppressed with a `.warmingUp` reason. This is the
    /// safety-critical fallback — if anything in the snapshot path is broken
    /// or stale, the watch must still wait out warmup before dosing.
    func test_b8_noSnapshot_firstIterationStillSuppressesWithWarmingUp() {
        WatchAlgorithmSnapshotCache.shared.resetForTesting()

        let (driver, store) = makeDriver(
            warmUpDecision: .fullWarmup(failedGate: .a_snapshotAge)
        )
        XCTAssertTrue(driver.isWarmingUp,
                      ".fullWarmup must keep isWarmingUp true at init")

        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(driver.underlyingRunner,
                                    didRecommend: (rec, date)) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(store.storedDecisions.count, 1,
                       "Fallback path must record exactly one decision (the warmingUp suppression)")
        XCTAssertEqual(
            store.storedDecisions.first?.reason,
            WatchDoseSuppressionReason.warmingUp.rawValue,
            "Fallback path must preserve today's warmingUp suppression behavior"
        )
    }
}
