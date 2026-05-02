//
//  WatchAlgorithmDriverTests.swift
//  WatchApp ExtensionTests
//
//  B.6 unit tests for the dose-suppression gate logic on the
//  didRecommend override. The full end-to-end test (algorithm runs
//  against emulated pod) lives in
//  OmniBLETests/Integration/WatchAlgorithmEndToEndTests.swift.
//

import XCTest
import Foundation
import HealthKit
import LoopAlgorithmCore
import LoopKit
import LoopCore
@testable import WatchAlgorithmKit
@testable import WatchApp_Extension  // for TimeInterval.minutes/.hours convenience

final class WatchAlgorithmDriverTests: XCTestCase {

    // MARK: - Mock pump manager that records calls

    /// Implements PumpManager with the minimum surface needed to serve
    /// `enactBolus` and `enactTempBasal`. All other protocol members are
    /// stubbed with sensible no-ops / empty defaults. Mirrors the
    /// MockPumpManager in LoopTests/Managers/DoseEnactorTests.swift.
    private final class RecordingPumpManager: PumpManager {

        var enactBolusCalls: [(units: Double, type: BolusActivationType)] = []
        var enactTempBasalCalls: [(unitsPerHour: Double, duration: TimeInterval)] = []

        // MARK: PumpManager required surface

        static let onboardingMaximumBasalScheduleEntryCount: Int = 24
        static let onboardingSupportedBasalRates: [Double] = [1, 2, 3]
        static let onboardingSupportedBolusVolumes: [Double] = [1, 2, 3]
        static let onboardingSupportedMaximumBolusVolumes: [Double] = [1, 2, 3]
        static let pluginIdentifier: String = "RecordingPumpManager"

        var supportedBasalRates: [Double] = [1, 2, 3]
        var supportedBolusVolumes: [Double] = [1, 2, 3]
        var supportedMaximumBolusVolumes: [Double] = [1, 2, 3]
        var maximumBasalScheduleEntryCount: Int = 24
        var minimumBasalScheduleEntryDuration: TimeInterval = .minutes(30)
        var pumpManagerDelegate: PumpManagerDelegate?
        var pumpRecordsBasalProfileStartEvents: Bool = false
        var pumpReservoirCapacity: Double = 50
        var lastSync: Date?
        var status: PumpManagerStatus = PumpManagerStatus(
            timeZone: TimeZone.current,
            device: HKDevice(name: "RecordingPumpManager", manufacturer: nil, model: nil,
                             hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                             localIdentifier: nil, udiDeviceIdentifier: nil),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: nil,
            bolusState: .noBolus,
            insulinType: .novolog
        )
        var localizedTitle: String = "RecordingPumpManager"
        var delegateQueue: DispatchQueue!
        var rawState: RawStateValue = [:]
        var isOnboarded: Bool = true
        var debugDescription: String = "RecordingPumpManager"

        init() {}

        required init?(rawState: RawStateValue) {}

        func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {}
        func removeStatusObserver(_ observer: PumpManagerStatusObserver) {}
        func ensureCurrentPumpData(completion: ((Date?) -> Void)?) { completion?(Date()) }
        func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {}
        func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? { nil }
        func estimatedDuration(toBolus units: Double) -> TimeInterval { .minutes(units / 1.5) }

        func enactBolus(units: Double,
                        activationType: BolusActivationType,
                        completion: @escaping (PumpManagerError?) -> Void) {
            enactBolusCalls.append((units, activationType))
            completion(nil)
        }

        func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
            completion(.success(nil))
        }

        func enactTempBasal(unitsPerHour: Double,
                            for duration: TimeInterval,
                            completion: @escaping (PumpManagerError?) -> Void) {
            enactTempBasalCalls.append((unitsPerHour, duration))
            completion(nil)
        }

        func suspendDelivery(completion: @escaping (Error?) -> Void) { completion(nil) }
        func resumeDelivery(completion: @escaping (Error?) -> Void) { completion(nil) }

        func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>],
                                   completion: @escaping (Swift.Result<BasalRateSchedule, Error>) -> Void) {}

        func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits,
                                completion: @escaping (Swift.Result<DeliveryLimits, Error>) -> Void) {}

        func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier,
                              completion: @escaping (Error?) -> Void) {}

        func getSoundBaseURL() -> URL? { nil }
        func getSounds() -> [Alert.Sound] { [] }
    }

    // MARK: - Mock decision store that records calls

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

    private func makeDriver(
        pumpManager: PumpManager?,
        automaticDosingEnabled: Bool = true,
        isAutomaticDosingAllowed: Bool = true,
        isWarmingUpOverride: Bool? = false
    ) -> (driver: WatchAlgorithmDriver, store: RecordingDecisionStore) {
        let store = RecordingDecisionStore()
        let snapshot = WatchSettingsSnapshot(
            automaticDosingEnabled: automaticDosingEnabled,
            isAutomaticDosingAllowed: isAutomaticDosingAllowed
        )
        let stores = makeStores()
        let driver = WatchAlgorithmDriver(
            carbStore: stores.carbStore,
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            dosingDecisionStore: store,
            settingsSnapshot: snapshot,
            pumpManager: pumpManager,
            isWarmingUpOverride: isWarmingUpOverride
        )
        return (driver, store)
    }

    private func sampleRecommendation()
        -> (recommendation: AutomaticDoseRecommendation, date: Date) {
        let basal = TempBasalRecommendation(unitsPerHour: 1.5, duration: 30 * 60)
        let rec = AutomaticDoseRecommendation(basalAdjustment: basal, bolusUnits: 0.0)
        return (rec, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Tests

    func testDidRecommend_allGatesPass_enactsDose() {
        let pump = RecordingPumpManager()
        let (driver, store) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true,
            isWarmingUpOverride: false
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(pump.enactTempBasalCalls.count, 1)
        XCTAssertEqual(pump.enactTempBasalCalls.first?.unitsPerHour, 1.5)
        XCTAssertEqual(pump.enactBolusCalls.count, 0,
                       "bolusUnits=0 means no enactBolus call")
        XCTAssertTrue(store.storedDecisions.isEmpty,
                      "Successful enactment should NOT record a suppressed decision")
    }

    func testDidRecommend_warmingUp_suppressesAndRecords() {
        let pump = RecordingPumpManager()
        let (driver, store) = makeDriver(
            pumpManager: pump,
            isWarmingUpOverride: true
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(pump.enactBolusCalls.count, 0)
        XCTAssertEqual(pump.enactTempBasalCalls.count, 0)
        XCTAssertEqual(store.storedDecisions.count, 1)
        XCTAssertEqual(store.storedDecisions.first?.reason,
                       WatchDoseSuppressionReason.warmingUp.rawValue)
    }

    func testDidRecommend_automaticDosingDisabled_suppressesAndRecords() {
        let pump = RecordingPumpManager()
        let (driver, store) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: false,
            isAutomaticDosingAllowed: true
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(pump.enactBolusCalls.count, 0)
        XCTAssertEqual(pump.enactTempBasalCalls.count, 0)
        XCTAssertEqual(store.storedDecisions.count, 1)
        XCTAssertEqual(store.storedDecisions.first?.reason,
                       WatchDoseSuppressionReason.automaticDosingDisabled.rawValue)
    }

    func testDidRecommend_dosingNotAllowed_suppressesAndRecords() {
        let pump = RecordingPumpManager()
        let (driver, store) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: false
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(pump.enactBolusCalls.count, 0)
        XCTAssertEqual(pump.enactTempBasalCalls.count, 0)
        XCTAssertEqual(store.storedDecisions.count, 1)
        XCTAssertEqual(store.storedDecisions.first?.reason,
                       WatchDoseSuppressionReason.automaticDosingNotAllowed.rawValue)
    }

    func testDidRecommend_noPumpManager_suppressesAndRecords() {
        let (driver, store) = makeDriver(pumpManager: nil)
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(store.storedDecisions.count, 1)
        XCTAssertEqual(store.storedDecisions.first?.reason,
                       WatchDoseSuppressionReason.noPumpManager.rawValue)
    }

    func testDidRecommend_warmingUpPlusDosingDisabled_recordsWarmingUp() {
        let pump = RecordingPumpManager()
        let (driver, store) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: false,
            isWarmingUpOverride: true
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(
            driver.underlyingRunner,
            didRecommend: (rec, date)
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(store.storedDecisions.count, 1)
        XCTAssertEqual(store.storedDecisions.first?.reason,
                       WatchDoseSuppressionReason.warmingUp.rawValue,
                       "Warming-up gate is first; its reason wins")
    }

    /// Pump reports deliveryIsUncertain → returns retryable error
    /// (NOT completion(nil)) so the algorithm will retry next tick.
    func testDidRecommend_deliveryIsUncertain_returnsErrorAndDoesNotEnact() {
        let pump = RecordingPumpManager()
        // Set up status with deliveryIsUncertain = true
        // (RecordingPumpManager.status is a stored mutable property)
        var status = pump.status
        status.deliveryIsUncertain = true
        pump.status = status

        let (driver, store) = makeDriver(pumpManager: pump,
                                          automaticDosingEnabled: true,
                                          isAutomaticDosingAllowed: true,
                                          isWarmingUpOverride: false)
        let exp = expectation(description: "didRecommend completion")
        var receivedError: LoopError?
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(driver.underlyingRunner,
                                    didRecommend: (rec, date)) { err in
            receivedError = err
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertNotNil(receivedError, "Gate 5 should return a retryable error")
        XCTAssertEqual(pump.enactBolusCalls.count, 0)
        XCTAssertEqual(pump.enactTempBasalCalls.count, 0)
        XCTAssertTrue(store.storedDecisions.isEmpty,
                      "Gate 5 does NOT record a suppressed decision (it returns an error to retry)")
    }
}
