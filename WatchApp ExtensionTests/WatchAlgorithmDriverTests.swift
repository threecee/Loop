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
import OmniBLE  // for PhoneWatchSettingsSync (B.5.2 #3 schedule-zone tests)
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
        isWarmingUpOverride: Bool? = false,
        recoveryDefaults: UserDefaults? = nil,  // B.5
        warmUpDecision: WarmUpDecision? = nil   // B.8
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
            isWarmingUpOverride: isWarmingUpOverride,
            recoveryDefaults: recoveryDefaults,
            warmUpDecision: warmUpDecision
        )
        return (driver, store)
    }

    // B.8: shared sample snapshot for warmup-decision tests.
    private func makeSampleSnapshot() -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: Date(),
            phoneIterationDate: Date(),
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 100,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: Date()),
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

    // MARK: - B.5: dose recovery store interaction

    /// A pump that returns a configurable error from enactTempBasal so we can
    /// exercise the early-return error branch of enactRecommendedDose.
    private final class FailingTempBasalPumpManager: PumpManager {
        var tempBasalError: PumpManagerError?
        var enactTempBasalCalls: [(unitsPerHour: Double, duration: TimeInterval)] = []
        var enactBolusCalls: [(units: Double, type: BolusActivationType)] = []

        static let onboardingMaximumBasalScheduleEntryCount: Int = 24
        static let onboardingSupportedBasalRates: [Double] = [1, 2, 3]
        static let onboardingSupportedBolusVolumes: [Double] = [1, 2, 3]
        static let onboardingSupportedMaximumBolusVolumes: [Double] = [1, 2, 3]
        static let pluginIdentifier: String = "FailingTempBasalPumpManager"

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
            device: HKDevice(name: "Failing", manufacturer: nil, model: nil,
                             hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                             localIdentifier: nil, udiDeviceIdentifier: nil),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: nil,
            bolusState: .noBolus,
            insulinType: .novolog
        )
        var localizedTitle: String = "Failing"
        var delegateQueue: DispatchQueue!
        var rawState: RawStateValue = [:]
        var isOnboarded: Bool = true
        var debugDescription: String = "Failing"

        init(error: PumpManagerError?) { self.tempBasalError = error }
        required init?(rawState: RawStateValue) {}

        func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {}
        func removeStatusObserver(_ observer: PumpManagerStatusObserver) {}
        func ensureCurrentPumpData(completion: ((Date?) -> Void)?) { completion?(Date()) }
        func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {}
        func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? { nil }
        func estimatedDuration(toBolus units: Double) -> TimeInterval { .minutes(units / 1.5) }

        func enactBolus(units: Double, activationType: BolusActivationType,
                        completion: @escaping (PumpManagerError?) -> Void) {
            enactBolusCalls.append((units, activationType))
            completion(nil)
        }
        func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
            completion(.success(nil))
        }
        func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval,
                            completion: @escaping (PumpManagerError?) -> Void) {
            enactTempBasalCalls.append((unitsPerHour, duration))
            completion(tempBasalError)
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

    /// Successful dose enactment clears the recovery store.
    func testDidRecommend_successfulDose_clearsRecoveryStore() {
        let suiteName = "B5_RecoveryStoreClearOnSuccess_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            WatchDoseRecoveryStore.clear(from: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }
        // Pre-populate with a stale-ish entry to confirm clear() runs.
        WatchDoseRecoveryStore.recordStart(description: "preexisting", to: defaults)
        XCTAssertNotNil(WatchDoseRecoveryStore.load(from: defaults), "precondition: entry exists")

        let pump = RecordingPumpManager()
        let (driver, _) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true,
            isWarmingUpOverride: false,
            recoveryDefaults: defaults
        )
        let exp = expectation(description: "didRecommend completion")
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(driver.underlyingRunner,
                                    didRecommend: (rec, date)) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(pump.enactTempBasalCalls.count, 1, "temp basal should have enacted")
        XCTAssertNil(WatchDoseRecoveryStore.load(from: defaults),
                     "Successful dose enactment should clear the recovery store")
    }

    // MARK: - B.5.2 Issue #3: schedule zone resolution from sync.timeZone

    /// `WatchSettingsSnapshot(fromSync:)` resolves a `scheduleZone` from
    /// `sync.timeZone` and threads it into the 4 schedule constructors. When
    /// the sync carries `"Europe/Copenhagen"`, the basal schedule's `timeZone`
    /// must equal that identifier — not the watch's local `TimeZone.current`.
    func testScheduleZoneDerivedFromSyncTimeZone() {
        let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!
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

        let snapshot = WatchSettingsSnapshot(fromSync: sync)

        XCTAssertEqual(snapshot.loopSettings.basalRateSchedule?.timeZone, copenhagen,
                       "basal schedule must use the sync's timeZone, not the watch's local zone")
        XCTAssertEqual(snapshot.loopSettings.insulinSensitivitySchedule?.timeZone, copenhagen,
                       "ISF schedule must use the sync's timeZone")
        XCTAssertEqual(snapshot.loopSettings.carbRatioSchedule?.timeZone, copenhagen,
                       "carb ratio schedule must use the sync's timeZone")
        XCTAssertEqual(snapshot.loopSettings.glucoseTargetRangeSchedule?.timeZone, copenhagen,
                       "glucose target range schedule must use the sync's timeZone")
    }

    /// When the sync's `timeZone` is nil (v3 senders before the field was added)
    /// the resolved zone must fall back to the watch's local `TimeZone.current`,
    /// preserving pre-B.5.2 behavior for backward compatibility.
    func testScheduleZoneFallsBackToCurrentWhenSyncTimeZoneNil() {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: 3,
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
            nightscoutConfig: nil
            // timeZone defaults to nil
        )

        let snapshot = WatchSettingsSnapshot(fromSync: sync)
        XCTAssertEqual(snapshot.loopSettings.basalRateSchedule?.timeZone, TimeZone.current,
                       "Nil sync.timeZone → schedule zone falls back to watch's TimeZone.current")
    }

    /// B.5.2 #3: malformed TimeZone identifiers (TimeZone(identifier:) → nil)
    /// fall back to TimeZone.current via the `??` in `flatMap(TimeZone.init(identifier:)) ?? TimeZone.current`.
    /// Protects against silent regression if anyone refactors to force-unwrap.
    func testScheduleZoneFallsBackToCurrentWhenSyncTimeZoneMalformed() {
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
            timeZone: "Bogus/NotAZone"
        )

        let snapshot = WatchSettingsSnapshot(fromSync: sync)
        XCTAssertEqual(snapshot.loopSettings.basalRateSchedule?.timeZone, TimeZone.current,
                       "Malformed sync.timeZone → schedule zone falls back to watch's TimeZone.current")
    }

    /// Temp-basal error early-return path also clears the recovery store.
    func testDidRecommend_tempBasalError_clearsRecoveryStore() {
        let suiteName = "B5_RecoveryStoreClearOnTempBasalError_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            WatchDoseRecoveryStore.clear(from: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let pump = FailingTempBasalPumpManager(error: .uncertainDelivery)
        let (driver, _) = makeDriver(
            pumpManager: pump,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true,
            isWarmingUpOverride: false,
            recoveryDefaults: defaults
        )
        let exp = expectation(description: "didRecommend completion")
        var receivedError: LoopError?
        let (rec, date) = sampleRecommendation()
        driver.loopAlgorithmRunner(driver.underlyingRunner,
                                    didRecommend: (rec, date)) { err in
            receivedError = err
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertNotNil(receivedError, "temp basal failure should propagate as LoopError")
        XCTAssertEqual(pump.enactTempBasalCalls.count, 1)
        XCTAssertEqual(pump.enactBolusCalls.count, 0,
                       "temp basal failure should short-circuit before bolus")
        XCTAssertNil(WatchDoseRecoveryStore.load(from: defaults),
                     "Early-return temp basal error path should still clear the recovery store")
    }

    // MARK: - B.8: warmup decision derivation at init

    /// `.skipWarmup(snapshot:)` must drive `isWarmingUp` to `false` at init.
    /// This is the production path that B.8 introduces: when the cache + CGM +
    /// pump-status freshness gates all pass, the driver bypasses warmup and
    /// is immediately eligible to dose.
    func test_init_skipsWarmupWhenDecisionSaysSkip() {
        let snap = makeSampleSnapshot()
        let (driver, _) = makeDriver(
            pumpManager: nil,
            isWarmingUpOverride: nil,
            warmUpDecision: .skipWarmup(snapshot: snap)
        )
        // B.8.4: hydration runs asynchronously inside a Task launched from
        // init; the .skipWarmup flag flip is gated on hydration success.
        // With empty buffers in this fixture, the Task completes very
        // quickly — wait for the flag transition before asserting.
        let exp = expectation(for: NSPredicate(block: { (obj, _) in
            (obj as? WatchAlgorithmDriver)?.isWarmingUp == false
        }), evaluatedWith: driver, handler: nil)
        wait(for: [exp], timeout: 5.0)
        XCTAssertFalse(driver.isWarmingUp,
                       "isWarmingUp must be false when WarmUpDecider returns skipWarmup")
    }

    /// `.fullWarmup(failedGate:)` keeps the pre-B.8 behavior: `isWarmingUp`
    /// stays `true` until the runner completes a full iteration.
    func test_init_isWarmingUpWhenDecisionSaysFullWarmup() {
        let (driver, _) = makeDriver(
            pumpManager: nil,
            isWarmingUpOverride: nil,
            warmUpDecision: .fullWarmup(failedGate: .a_snapshotAge)
        )
        XCTAssertTrue(driver.isWarmingUp,
                      "isWarmingUp must remain true on fullWarmup fallback")
    }
}

// MARK: - B.8.4 Phase 6: hydration unit tests
//
// `WatchAlgorithmDriver.applyAlgorithmStateSnapshot(_:carbStore:doseStore:glucoseStore:)`
// is the static async throws helper that flushes the snapshot's three buffers
// into the runner-backing stores before the driver flips out of warmup. These
// tests exercise the freshness guard (gating) and the buffered-write contract
// (functional). The freshness extension method lives on `AlgorithmStateSnapshot`
// in OmniBLE.
//
// Guarded with `#if !os(iOS)` to mirror the watch-only nature of the
// production driver — the WatchApp ExtensionTests target only builds for
// watchOS, but the guard makes the intent explicit and survives any future
// target reshuffling.

#if !os(iOS)

final class WatchAlgorithmDriverHydrationTests: XCTestCase {

    // MARK: - Helpers

    /// Holds the three concrete stores used by the hydration test. We keep
    /// concrete types (vs. `WatchAlgorithmStores` which wraps via protocols)
    /// so the test can call `getGlucoseSamples` / `getDoses` / `getCarbEntries`
    /// directly — those query helpers aren't on the algorithm-core protocols.
    private struct ConcreteStores {
        let carbStore: CarbStore
        let doseStore: DoseStore
        let glucoseStore: GlucoseStore
    }

    private func makeConcreteStores() -> ConcreteStores {
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
        return ConcreteStores(carbStore: carbStore, doseStore: doseStore, glucoseStore: glucoseStore)
    }

    private func makePumpStatus() -> PumpStatusSnapshot {
        PumpStatusSnapshot(
            reservoirUnitsRemaining: 100,
            lastBasalRateUnitsPerHour: 0.5,
            isSuspended: false,
            lastReadingDate: Date()
        )
    }

    /// Snapshot with an empty buffers but a fresh `phoneIterationDate`.
    private func makeFreshSnapshot(now: Date = Date()) -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now.addingTimeInterval(-30),  // 30s old → fresh
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: makePumpStatus(),
            activeOverride: nil
        )
    }

    /// Snapshot with `phoneIterationDate` 10 minutes in the past — well past
    /// the 7-minute `maxAgeForSkipWarmup` threshold.
    private func makeStaleSnapshot(now: Date = Date()) -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now.addingTimeInterval(-10 * 60),  // 10 min old → stale
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: makePumpStatus(),
            activeOverride: nil
        )
    }

    // MARK: - Freshness guard

    /// 30s-old snapshots pass the 7-minute freshness window.
    func test_skipWarmup_freshSnapshotPassesGuard() {
        let snapshot = makeFreshSnapshot()
        XCTAssertTrue(snapshot.isFreshEnoughForSkipWarmup(),
                      "Fresh snapshot (30s old) must pass the skip-warmup freshness guard")
    }

    /// 10-minute-old snapshots fail the 7-minute freshness window.
    func test_skipWarmup_staleSnapshotFailsGuard() {
        let snapshot = makeStaleSnapshot()
        XCTAssertFalse(snapshot.isFreshEnoughForSkipWarmup(),
                       "Stale snapshot (10 min old) must fail the skip-warmup freshness guard")
    }

    // MARK: - Buffer hydration

    /// Verifies all three buffers (glucose / dose / carb) land in their
    /// respective stores when `applyAlgorithmStateSnapshot` runs.
    func test_applyAlgorithmStateSnapshot_writesAllThreeBuffers() async throws {
        let stores = makeConcreteStores()
        let now = Date()

        var glucoseSamples: [StoredGlucoseSample] = []
        for i in 0..<3 {
            let offset: TimeInterval = -300 * Double(3 - i)
            let value: Double = 100.0 + Double(i)
            glucoseSamples.append(
                StoredGlucoseSample(
                    syncIdentifier: "glucose-\(i)",
                    syncVersion: 1,
                    startDate: now.addingTimeInterval(offset),
                    quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
                )
            )
        }

        var doseHistory: [DoseEntry] = []
        for i in 0..<2 {
            let startOffset: TimeInterval = -600 * Double(2 - i)
            let endOffset: TimeInterval = startOffset + 300
            let unitsPerHour: Double = 0.5 + Double(i) * 0.1
            doseHistory.append(
                DoseEntry(
                    type: .tempBasal,
                    startDate: now.addingTimeInterval(startOffset),
                    endDate: now.addingTimeInterval(endOffset),
                    value: unitsPerHour,
                    unit: .unitsPerHour,
                    syncIdentifier: "dose-\(i)"
                )
            )
        }

        let carbEntry = StoredCarbEntry(
            startDate: now.addingTimeInterval(-1800),
            quantity: HKQuantity(unit: .gram(), doubleValue: 25.0),
            syncIdentifier: "carb-0",
            syncVersion: 1,
            absorptionTime: .hours(3)
        )

        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now.addingTimeInterval(-30),
            glucoseSamples: glucoseSamples,
            doseHistory: doseHistory,
            carbEntries: [carbEntry],
            pumpStatus: makePumpStatus(),
            activeOverride: nil
        )

        // Act
        try await WatchAlgorithmDriver.applyAlgorithmStateSnapshot(
            snapshot,
            carbStore: stores.carbStore,
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore
        )

        // Assert: glucose store received 3 samples.
        let storedGlucose = try await stores.glucoseStore.getGlucoseSamples()
        XCTAssertEqual(storedGlucose.count, 3,
                       "All 3 glucose samples should have been written to the glucose store")

        // Assert: dose store received 2 doses. Use the basalProfile-independent
        // `getDoses` API (vs. `getNormalizedDoseEntries`) so the test doesn't
        // need to seed a basal profile on the test DoseStore.
        let storedDoses = try await stores.doseStore.getDoses()
        XCTAssertEqual(storedDoses.count, 2,
                       "All 2 dose entries should have been written to the dose store")

        // Assert: carb store received 1 entry.
        let storedCarbs = try await stores.carbStore.getCarbEntries()
        XCTAssertEqual(storedCarbs.count, 1,
                       "The 1 carb entry should have been written to the carb store")
    }
}

#endif
