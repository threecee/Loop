//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//
//  B.3.a Phase 2.E: rewired to delegate algorithm work to
//  `LoopAlgorithmRunner` (in LoopAlgorithmCore). LoopDataManager now owns
//  a runner, conforms to `LoopAlgorithmRunnerDelegate` plus the three
//  provider protocols, and bridges iOS-specific orchestration
//  (NotificationCenter, WidgetKit, LiveActivity, Analytics,
//  MealDetectionManager, presetActivationObservers, intent observer,
//  background tasks) into delegate callbacks. Algorithm method bodies live
//  on the runner; LoopDataManager keeps thin wrappers so existing iOS call
//  sites (DeviceDataManager, view controllers, WatchDataManager, etc.)
//  continue to work unchanged.
//

import Foundation
import Combine
import HealthKit
import LoopAlgorithmCore
import LoopKit
import LoopCore
import WidgetKit

protocol PresetActivationObserver: AnyObject {
    func presetActivated(context: TemporaryScheduleOverride.Context, duration: TemporaryScheduleOverride.Duration)
    func presetDeactivated(context: TemporaryScheduleOverride.Context)
}

final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case insulin
        case carbs
        case glucose
        case preferences
        case loopFinished
    }

    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    // MARK: Stored collaborators

    private let carbStore: CarbStoreProtocol

    private let mealDetectionManager: MealDetectionManager

    private let doseStore: DoseStoreProtocol

    let dosingDecisionStore: DosingDecisionStoreProtocol

    private let glucoseStore: GlucoseStoreProtocol

    let latestStoredSettingsProvider: LatestStoredSettingsProvider

    weak var delegate: LoopDataManagerDelegate?

    private let logger = DiagnosticLog(category: "LoopDataManager")
    private let widgetLog = DiagnosticLog(category: "LoopWidgets")

    private let analyticsServicesManager: AnalyticsServicesManager

    /// B.8: end-of-iteration algorithm-state snapshot emitter. Wired up by
    /// LoopAppManager during init.
    weak var algorithmStateSnapshotEmitter: AlgorithmStateSnapshotEmitter?

    private let trustedTimeOffset: () -> TimeInterval

    private let now: () -> Date

    private let automaticDosingStatus: AutomaticDosingStatus

    lazy private var cancellables = Set<AnyCancellable>()

    // References to registered notification center observers
    private var notificationObservers: [Any] = []

    private var overrideIntentObserver: NSKeyValueObservation? = nil

    var presetActivationObservers: [PresetActivationObserver] = []

    private var liveActivityManager: LiveActivityManagerProxy?

    // MARK: - Algorithm runner (B.3.a Phase 2.E)

    /// The cross-platform algorithm engine. Owns all algorithm cached state
    /// (carbEffect, insulinEffect, predictedGlucose, etc.) and serializes
    /// loop iterations on its own internal queue. LoopDataManager forwards
    /// every algorithm-side call to this object and receives lifecycle /
    /// orchestration callbacks via the `LoopAlgorithmRunnerDelegate`
    /// conformance below.
    private let runner: LoopAlgorithmRunner

    // MARK: - Public surface (most properties forward to the runner)

    let loopLock = UnfairLock()

    var settings: LoopSettings { runner.settings }

    @Published private(set) var dosingEnabled: Bool

    let overrideHistory: TemporaryScheduleOverrideHistory

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? {
        get { runner.basalDeliveryState }
        set { runner.basalDeliveryState = newValue }
    }

    var pumpInsulinType: InsulinType? {
        get { runner.pumpInsulinType }
        set { runner.pumpInsulinType = newValue }
    }

    var lastLoopCompleted: Date? {
        get { runner.lastLoopCompleted }
        set { runner.lastLoopCompleted = newValue }
    }

    var remoteRecommendationNeedsUpdating: Bool {
        get { runner.remoteRecommendationNeedsUpdating }
        set { runner.remoteRecommendationNeedsUpdating = newValue }
    }

    var retrospectiveCorrection: RetrospectiveCorrection { runner.retrospectiveCorrection }

    func clearCachedInsulinEffects() {
        runner.clearCachedInsulinEffects()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init(
        lastLoopCompleted: Date?,
        basalDeliveryState: PumpManagerStatus.BasalDeliveryState?,
        settings: LoopSettings,
        overrideHistory: TemporaryScheduleOverrideHistory,
        analyticsServicesManager: AnalyticsServicesManager,
        localCacheDuration: TimeInterval = .days(1),
        doseStore: DoseStoreProtocol,
        glucoseStore: GlucoseStoreProtocol,
        carbStore: CarbStoreProtocol,
        dosingDecisionStore: DosingDecisionStoreProtocol,
        latestStoredSettingsProvider: LatestStoredSettingsProvider,
        now: @escaping () -> Date = { Date() },
        pumpInsulinType: InsulinType?,
        automaticDosingStatus: AutomaticDosingStatus,
        trustedTimeOffset: @escaping () -> TimeInterval
    ) {
        self.analyticsServicesManager = analyticsServicesManager
        self.dosingEnabled = settings.dosingEnabled

        self.overrideHistory = overrideHistory

        let absorptionTimes = LoopCoreConstants.defaultCarbAbsorptionTimes
        self.overrideHistory.relevantTimeWindow = absorptionTimes.slow * 2

        self.carbStore = carbStore
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore

        self.dosingDecisionStore = dosingDecisionStore

        self.now = now

        self.latestStoredSettingsProvider = latestStoredSettingsProvider
        self.mealDetectionManager = MealDetectionManager(
            carbRatioScheduleApplyingOverrideHistory: carbStore.carbRatioScheduleApplyingOverrideHistory,
            insulinSensitivityScheduleApplyingOverrideHistory: carbStore.insulinSensitivityScheduleApplyingOverrideHistory,
            maximumBolus: settings.maximumBolus
        )

        self.automaticDosingStatus = automaticDosingStatus

        self.trustedTimeOffset = trustedTimeOffset

        self.runner = LoopAlgorithmRunner(
            lastLoopCompleted: lastLoopCompleted,
            basalDeliveryState: basalDeliveryState,
            settings: settings,
            overrideHistory: overrideHistory,
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: LatestStoredSettingsRunnerAdapter(provider: latestStoredSettingsProvider),
            controllerStatusProvider: ControllerStatusProviderAdapter(),
            featureFlagProvider: IOSAlgorithmFeatureFlagProvider(),
            automaticDosingStatus: AutomaticDosingStatusRunnerAdapter(status: automaticDosingStatus),
            pumpInsulinType: pumpInsulinType,
            trustedTimeOffset: trustedTimeOffset,
            now: now
        )

        // Wire delegate after self has been fully initialized (delegate is
        // weak so the cycle is fine; we just can't pass `self` to a
        // non-optional init parameter).
        self.runner.delegate = self

        if #available(iOS 16.2, *) {
            self.liveActivityManager = LiveActivityManager(
                glucoseStore: self.glucoseStore,
                doseStore: self.doseStore,
                loopSettings: self.settings
            )
        }

        overrideIntentObserver = UserDefaults.appGroup?.observe(\.intentExtensionOverrideToSet, options: [.new], changeHandler: {[weak self] (defaults, change) in
            guard let name = change.newValue??.lowercased(), let appGroup = UserDefaults.appGroup else {
                return
            }

            guard let preset = self?.settings.overridePresets.first(where: {$0.name.lowercased() == name}) else {
                self?.logger.error("Override Intent: Unable to find override named '%s'", String(describing: name))
                return
            }

            self?.logger.default("Override Intent: setting override named '%s'", String(describing: name))
            self?.mutateSettings { settings in
                if let oldPreset = settings.scheduleOverride {
                    if let observers = self?.presetActivationObservers {
                        for observer in observers {
                            observer.presetDeactivated(context: oldPreset.context)
                        }
                    }
                }

                settings.scheduleOverride = preset.createOverride(enactTrigger: .remote("Siri"))
                if let observers = self?.presetActivationObservers {
                    for observer in observers {
                        observer.presetActivated(context: .preset(preset), duration: preset.duration)
                    }
                }
                self?.liveActivityManager?.update(loopSettings: settings)
            }
            // Remove the override from UserDefaults so we don't set it multiple times
            appGroup.intentExtensionOverrideToSet = nil
        })

        // Required for device settings in stored dosing decisions
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif

        // Observe changes
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: CarbStore.carbEntriesDidChange,
                object: self.carbStore,
                queue: nil
            ) { (note) -> Void in
                self.runner.handleCarbEntriesDidChange()
                self.liveActivityManager?.update(loopSettings: self.settings)
            },
            NotificationCenter.default.addObserver(
                forName: GlucoseStore.glucoseSamplesDidChange,
                object: self.glucoseStore,
                queue: nil
            ) { (note) in
                self.runner.handleGlucoseSamplesDidChange()
                self.liveActivityManager?.update(loopSettings: self.settings)
            },
            NotificationCenter.default.addObserver(
                forName: nil,
                object: self.doseStore,
                queue: OperationQueue.main
            ) { (note) in
                self.runner.handleDoseStoreDidChange()
                self.liveActivityManager?.update(loopSettings: self.settings)
            }
        ]

        // Turn off preMeal when going into closed loop off mode
        // Cancel any active temp basal when going into closed loop off mode
        // The dispatch is necessary in case this is coming from a didSet already on the settings struct.
        self.automaticDosingStatus.$automaticDosingEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                if !$0 {
                    self?.mutateSettings { settings in
                        settings.clearOverride(matching: .preMeal)
                    }
                    self?.runner.cancelActiveTempBasal(for: .automaticDosingDisabled)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Settings mutation

    /// Apply settings changes via the runner. The runner mutates its own
    /// state and synchronously calls back into us via
    /// `loopAlgorithmRunner(_:settingsDidChange:)` so we can fan out to
    /// MealDetectionManager / LiveActivity / analytics / preset observers.
    func mutateSettings(_ changes: (_ settings: inout LoopSettings) -> Void) {
        runner.mutateSettings(changes)
    }

    // MARK: - Background task management

    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PersistenceController save") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    #else
    private func startBackgroundTask() { /* no-op on watchOS */ }
    private func endBackgroundTask() { /* no-op on watchOS */ }
    #endif

    // MARK: - Remote recommendation

    func updateRemoteRecommendation() {
        runner.updateRemoteRecommendation()
    }

    // MARK: - Provider adapters

    /// Adapter so the iOS `LatestStoredSettingsProvider` (a more general
    /// protocol used elsewhere in the app) satisfies the runner's
    /// `LoopAlgorithmLatestStoredSettingsProvider` protocol.
    private final class LatestStoredSettingsRunnerAdapter: LoopAlgorithmLatestStoredSettingsProvider {
        let provider: LatestStoredSettingsProvider
        init(provider: LatestStoredSettingsProvider) { self.provider = provider }
        var latestSettings: StoredSettings { provider.latestSettings }
    }

    /// Adapter wrapping iOS `AutomaticDosingStatus` so the runner sees the
    /// `AutomaticDosingStatusBridge` protocol (cross-platform).
    private final class AutomaticDosingStatusRunnerAdapter: AutomaticDosingStatusBridge {
        let status: AutomaticDosingStatus
        init(status: AutomaticDosingStatus) { self.status = status }
        var automaticDosingEnabled: Bool { status.automaticDosingEnabled }
        var isAutomaticDosingAllowed: Bool { status.isAutomaticDosingAllowed }
    }

    /// Provides the host controller status. The runner folds this into
    /// every persisted `StoredDosingDecision` so reports can show whether
    /// the iOS device was charging / battery-low at decision time. iOS
    /// reads `UIDevice.controllerStatus`; the watch shim will provide
    /// its own implementation.
    private final class ControllerStatusProviderAdapter: LoopAlgorithmControllerStatusProvider {
        var controllerStatus: StoredDosingDecision.ControllerStatus? {
            #if os(iOS)
            return UIDevice.current.controllerStatus
            #else
            return nil
            #endif
        }
    }

    /// iOS feature-flag provider — reads UserDefaults / FeatureFlags exactly
    /// as the original iOS LoopDataManager did.
    private final class IOSAlgorithmFeatureFlagProvider: LoopAlgorithmFeatureFlagProvider {
        var integralRetrospectiveCorrectionEnabled: Bool {
            UserDefaults.standard.integralRetrospectiveCorrectionEnabled
        }
        var glucoseBasedApplicationFactorEnabled: Bool {
            UserDefaults.standard.glucoseBasedApplicationFactorEnabled
        }
        var missedMealNotificationsEnabled: Bool {
            FeatureFlags.missedMealNotifications
        }
    }
}

// MARK: Background task management
extension LoopDataManager: PersistenceControllerDelegate {
    func persistenceControllerWillSave(_ controller: PersistenceController) {
        startBackgroundTask()
    }

    func persistenceControllerDidSave(_ controller: PersistenceController, error: PersistenceController.PersistenceControllerError?) {
        endBackgroundTask()
    }
}

// MARK: - Preferences (forwarding to runner)
extension LoopDataManager {

    var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        runner.basalRateScheduleApplyingOverrideHistory
    }

    var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        runner.carbRatioScheduleApplyingOverrideHistory
    }

    var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        runner.insulinSensitivityScheduleApplyingOverrideHistory
    }

    func setScheduleTimeZone(_ timeZone: TimeZone) {
        runner.setScheduleTimeZone(timeZone)
    }
}


// MARK: - Intake (forwarding to runner)
extension LoopDataManager {
    func addGlucoseSamples(
        _ samples: [NewGlucoseSample],
        completion: ((_ result: Swift.Result<[StoredGlucoseSample], Error>) -> Void)? = nil
    ) {
        runner.addGlucoseSamples(samples, completion: completion)
    }

    func receivedUnreliableCGMReading() {
        runner.receivedUnreliableCGMReading()
    }

    func addCarbEntry(_ carbEntry: NewCarbEntry, replacing replacingEntry: StoredCarbEntry? = nil, completion: @escaping (_ result: Result<StoredCarbEntry>) -> Void) {
        runner.addCarbEntry(carbEntry, replacing: replacingEntry, completion: completion)
    }

    func deleteCarbEntry(_ oldEntry: StoredCarbEntry, completion: @escaping (_ result: CarbStoreResult<Bool>) -> Void) {
        runner.deleteCarbEntry(oldEntry, completion: completion)
    }

    func addRequestedBolus(_ dose: DoseEntry, completion: (() -> Void)?) {
        runner.addRequestedBolus(dose, completion: completion)
    }

    func bolusConfirmed(completion: (() -> Void)?) {
        runner.bolusConfirmed(completion: completion)
    }

    func bolusRequestFailed(_ error: Error, completion: (() -> Void)?) {
        runner.bolusRequestFailed(error, completion: completion)
    }

    func addManuallyEnteredDose(startDate: Date, units: Double, insulinType: InsulinType? = nil) {
        runner.addManuallyEnteredDose(startDate: startDate, units: units, insulinType: insulinType)
    }

    func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        runner.addReservoirValue(units, at: date, completion: completion)
    }

    func storeManualBolusDosingDecision(_ bolusDosingDecision: BolusDosingDecision, withDate date: Date) {
        runner.storeManualBolusDosingDecision(bolusDosingDecision, withDate: date)
    }

    // Actions

    func loop() {
        runner.loop()
    }

    func loopInternal() {
        runner.loopInternal()
    }

    func maxTempBasalSavePreflight(unitsPerHour: Double?, completion: @escaping (_ error: Error?) -> Void) {
        runner.maxTempBasalSavePreflight(unitsPerHour: unitsPerHour, completion: completion)
    }
}

// MARK: - LoopAlgorithmRunnerDelegate (iOS orchestration)

extension LoopDataManager: LoopAlgorithmRunnerDelegate {

    // Lifecycle

    func loopAlgorithmRunnerDidStartLoop(_ runner: LoopAlgorithmRunner) {
        NotificationCenter.default.post(name: .LoopRunning, object: self)
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidComplete date: Date,
                             duration: TimeInterval) {
        analyticsServicesManager.loopDidSucceed(duration)
        NotificationCenter.default.post(name: .LoopCompleted, object: self)
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidError error: LoopError,
                             duration: TimeInterval) {
        analyticsServicesManager.loopDidError(error: error)
    }

    func loopAlgorithmRunnerDidFinishLoop(_ runner: LoopAlgorithmRunner) {
        // B.8: push algorithm-state snapshot to watch (no-op if emitter unwired).
        algorithmStateSnapshotEmitter?.emit()

        // 5 second delay to allow stores to cache data before it is read by widget
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.widgetLog.default("Refreshing widget. Reason: Loop completed")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didChange context: LoopAlgorithmUpdateContext) {
        // Map the LoopAlgorithmCore context enum to the iOS-side
        // LoopUpdateContext (same raw values) and post the legacy
        // notification that downstream iOS observers expect.
        guard let mapped = LoopUpdateContext(rawValue: context.rawValue) else { return }
        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: [
                type(of: self).LoopUpdateContextKey: mapped.rawValue
            ]
        )
    }

    // Settings change

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             settingsDidChange impact: LoopAlgorithmSettingsChangeImpact) {
        let oldValue = impact.oldSettings
        let newValue = impact.newSettings

        dosingEnabled = newValue.dosingEnabled

        if impact.preMealOverrideChanged {
            self.liveActivityManager?.update(loopSettings: newValue)
        }

        if impact.scheduleOverrideChanged {
            if let oldPreset = oldValue.scheduleOverride {
                for observer in self.presetActivationObservers {
                    observer.presetDeactivated(context: oldPreset.context)
                }
                self.liveActivityManager?.update(loopSettings: newValue)
            }
            if let newPreset = newValue.scheduleOverride {
                for observer in self.presetActivationObservers {
                    observer.presetActivated(context: newPreset.context, duration: newPreset.duration)
                }
                self.liveActivityManager?.update(loopSettings: newValue)
            }

            // Update the affected schedules
            mealDetectionManager.carbRatioScheduleApplyingOverrideHistory = carbRatioScheduleApplyingOverrideHistory
            mealDetectionManager.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivityScheduleApplyingOverrideHistory
        }

        if impact.insulinSensitivityScheduleChanged {
            mealDetectionManager.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivityScheduleApplyingOverrideHistory
            analyticsServicesManager.didChangeInsulinSensitivitySchedule()
        }

        if impact.basalRateScheduleChanged {
            analyticsServicesManager.didChangeBasalRateSchedule()
        }

        if impact.carbRatioScheduleChanged {
            mealDetectionManager.carbRatioScheduleApplyingOverrideHistory = carbRatioScheduleApplyingOverrideHistory
            analyticsServicesManager.didChangeCarbRatioSchedule()
        }

        if impact.insulinModelChanged {
            if FeatureFlags.adultChildInsulinModelSelectionEnabled {
                doseStore.insulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: newValue.defaultRapidActingModel)
            } else {
                doseStore.insulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
            }
            analyticsServicesManager.didChangeInsulinModel()
        }

        if impact.maximumBolusChanged {
            mealDetectionManager.maximumBolus = newValue.maximumBolus
        }

        analyticsServicesManager.didChangeLoopSettings(from: oldValue, to: newValue)
    }

    // Pump enactment + rounding

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
                             completion: @escaping (LoopError?) -> Void) {
        guard let delegate = delegate else {
            completion(nil)
            return
        }
        delegate.loopDataManager(self, didRecommend: automaticDose, completion: completion)
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBasalRate unitsPerHour: Double) -> Double {
        delegate?.roundBasalRate(unitsPerHour: unitsPerHour) ?? unitsPerHour
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBolusVolume units: Double) -> Double {
        delegate?.roundBolusVolume(units: units) ?? units
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             estimateBolusDuration units: Double) -> TimeInterval? {
        delegate?.loopDataManager(self, estimateBolusDuration: units)
    }

    // Pump / CGM status snapshots

    var pumpManagerStatusForRunner: PumpManagerStatus? { delegate?.pumpManagerStatus }
    var pumpStatusHighlightForRunner: DeviceStatusHighlight? { delegate?.pumpStatusHighlight }
    var cgmManagerStatusForRunner: CGMManagerStatus? { delegate?.cgmManagerStatus }

    // Missed-meal hand-off (iOS forwards to MealDetectionManager)

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             checkMissedMealWithGlucoseSamples glucoseSamples: [StoredGlucoseSample],
                             insulinCounteractionEffects: [GlucoseEffectVelocity],
                             carbEffects: [GlucoseEffect],
                             pendingAutobolusUnits: Double?) {
        mealDetectionManager.generateMissedMealNotificationIfNeeded(
            glucoseSamples: glucoseSamples,
            insulinCounteractionEffects: insulinCounteractionEffects,
            carbEffects: carbEffects,
            pendingAutobolusUnits: pendingAutobolusUnits,
            bolusDurationEstimator: { [weak self] bolusAmount in
                guard let self = self else { return nil }
                return self.delegate?.loopDataManager(self, estimateBolusDuration: bolusAmount)
            }
        )
    }

    // Issue conversion (iOS-rich `LoopError.issue` / `LoopWarning.issue`)

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor error: LoopError) -> StoredDosingDecision.Issue {
        return error.issue
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor warning: LoopAlgorithmWarning) -> StoredDosingDecision.Issue {
        return warning.iosLoopWarning.issue
    }
}

// MARK: - LoopState (visualization-only view into runner state)

protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    /// The last-calculated insulin on board
    var insulinOnBoard: InsulinValue? { get }

    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: LoopError? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [PredictedGlucoseValue]? { get }

    /// The calculated timeline of predicted glucose values, including the effects of pending insulin
    var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)? { get }

    /// The difference in predicted vs actual glucose over a recent period
    var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? { get }

    /// The total corrective glucose effect from retrospective correction
    var totalRetrospectiveCorrection: HKQuantity? { get }

    func predictGlucose(using inputs: PredictionInputEffect, potentialBolus: DoseEntry?, potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, includingPendingInsulin: Bool, considerPositiveVelocityAndRC: Bool) throws -> [PredictedGlucoseValue]

    func predictGlucoseFromManualGlucose(
        _ glucose: NewGlucoseSample,
        potentialBolus: DoseEntry?,
        potentialCarbEntry: NewCarbEntry?,
        replacingCarbEntry replacedCarbEntry: StoredCarbEntry?,
        includingPendingInsulin: Bool,
        considerPositiveVelocityAndRC: Bool
    ) throws -> [PredictedGlucoseValue]

    func recommendBolus(consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation?

    func recommendBolusForManualGlucose(_ glucose: NewGlucoseSample, consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation?
}

extension LoopState {
    func predictGlucose(using inputs: PredictionInputEffect, includingPendingInsulin: Bool = false) throws -> [GlucoseValue] {
        try predictGlucose(using: inputs, potentialBolus: nil, potentialCarbEntry: nil, replacingCarbEntry: nil, includingPendingInsulin: includingPendingInsulin, considerPositiveVelocityAndRC: true)
    }
}

extension LoopDataManager {
    private struct LoopStateView: LoopState {

        private let runner: LoopAlgorithmRunner
        private let updateError: LoopError?

        init(runner: LoopAlgorithmRunner, updateError: LoopError?) {
            self.runner = runner
            self.updateError = updateError
        }

        var carbsOnBoard: CarbValue? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.carbsOnBoard
        }

        var insulinOnBoard: InsulinValue? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.insulinOnBoard
        }

        var error: LoopError? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return updateError ?? runner.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.insulinCounteractionEffects
        }

        var predictedGlucose: [PredictedGlucoseValue]? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.predictedGlucose
        }

        var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.predictedGlucoseIncludingPendingInsulin
        }

        var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            guard runner.lastRequestedBolus == nil else {
                return nil
            }
            return runner.recommendedAutomaticDose
        }

        var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.retrospectiveGlucoseDiscrepanciesSummed
        }

        var totalRetrospectiveCorrection: HKQuantity? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return runner.retrospectiveCorrection.totalGlucoseCorrectionEffect
        }

        func predictGlucose(using inputs: PredictionInputEffect, potentialBolus: DoseEntry?, potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, includingPendingInsulin: Bool, considerPositiveVelocityAndRC: Bool) throws -> [PredictedGlucoseValue] {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return try runner.predictGlucose(using: inputs, potentialBolus: potentialBolus, potentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, includingPendingInsulin: includingPendingInsulin, includingPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        }

        func predictGlucoseFromManualGlucose(
            _ glucose: NewGlucoseSample,
            potentialBolus: DoseEntry?,
            potentialCarbEntry: NewCarbEntry?,
            replacingCarbEntry replacedCarbEntry: StoredCarbEntry?,
            includingPendingInsulin: Bool,
            considerPositiveVelocityAndRC: Bool
        ) throws -> [PredictedGlucoseValue] {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return try runner.predictGlucoseFromManualGlucose(glucose, potentialBolus: potentialBolus, potentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, includingPendingInsulin: includingPendingInsulin, considerPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        }

        func recommendBolus(consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return try runner.recommendBolus(consideringPotentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, considerPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        }

        func recommendBolusForManualGlucose(_ glucose: NewGlucoseSample, consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation? {
            runner.dispatchPrecondition_assertOnDataAccessQueue()
            return try runner.recommendBolusForManualGlucose(glucose, consideringPotentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, considerPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        }
    }

    /// Executes a closure with access to the current state of the loop. The
    /// state is computed by the runner; the closure is run on the runner's
    /// internal data-access queue.
    func getLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        runner.runOnDataAccessQueue { [weak self] in
            guard let self = self else { return }
            let updateError = self.runner.runUpdateForGetLoopState()
            handler(self, LoopStateView(runner: self.runner, updateError: updateError))
        }
    }

    func generateSimpleBolusRecommendation(at date: Date, mealCarbs: HKQuantity?, manualGlucose: HKQuantity?) -> BolusDosingDecision? {

        var dosingDecision = BolusDosingDecision(for: .simpleBolus)

        var activeInsulin: Double? = nil
        let semaphore = DispatchSemaphore(value: 0)
        doseStore.insulinOnBoard(at: Date()) { (result) in
            if case .success(let iobValue) = result {
                activeInsulin = iobValue.value
                dosingDecision.insulinOnBoard = iobValue
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let iob = activeInsulin,
            let suspendThreshold = settings.suspendThreshold?.quantity,
            let carbRatioSchedule = carbStore.carbRatioScheduleApplyingOverrideHistory,
            let correctionRangeSchedule = settings.effectiveGlucoseTargetRangeSchedule(presumingMealEntry: mealCarbs != nil),
            let sensitivitySchedule = insulinSensitivityScheduleApplyingOverrideHistory
        else {
            // Settings incomplete; should never get here; remove when therapy settings non-optional
            return nil
        }

        if let scheduleOverride = settings.scheduleOverride, !scheduleOverride.hasFinished() {
            dosingDecision.scheduleOverride = settings.scheduleOverride
        }

        dosingDecision.glucoseTargetRangeSchedule = correctionRangeSchedule

        var notice: BolusRecommendationNotice? = nil
        if let manualGlucose = manualGlucose {
            let glucoseValue = SimpleGlucoseValue(startDate: date, quantity: manualGlucose)
            if manualGlucose < suspendThreshold {
                notice = .glucoseBelowSuspendThreshold(minGlucose: glucoseValue)
            } else {
                let correctionRange = correctionRangeSchedule.quantityRange(at: date)
                if manualGlucose < correctionRange.lowerBound {
                    notice = .currentGlucoseBelowTarget(glucose: glucoseValue)
                }
            }
        }

        let bolusAmount = SimpleBolusCalculator.recommendedInsulin(
            mealCarbs: mealCarbs,
            manualGlucose: manualGlucose,
            activeInsulin: HKQuantity.init(unit: .internationalUnit(), doubleValue: iob),
            carbRatioSchedule: carbRatioSchedule,
            correctionRangeSchedule: correctionRangeSchedule,
            sensitivitySchedule: sensitivitySchedule,
            at: date)

        dosingDecision.manualBolusRecommendation = ManualBolusRecommendationWithDate(recommendation: ManualBolusRecommendation(amount: bolusAmount.doubleValue(for: .internationalUnit()), pendingInsulin: 0, notice: notice),
                                                                                     date: Date())

        return dosingDecision
    }
}

// MARK: - Diagnostic report

extension LoopDataManager {
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        getLoopState { (manager, state) in

            var entries: [String] = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",

                "insulinCounteractionEffects: [",
                "* GlucoseEffectVelocity(start, end, mg/dL/min)",
                manager.runner.insulinCounteractionEffects.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n")
                }),
                "]",

                "insulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.runner.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "carbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.runner.carbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "predictedGlucose: [",
                "* PredictedGlucoseValue(start, mg/dL)",
                (state.predictedGlucoseIncludingPendingInsulin ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "integralRetrospectiveCorrectionEnabled: \(UserDefaults.standard.integralRetrospectiveCorrectionEnabled)",

                "retrospectiveGlucoseDiscrepancies: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.runner.retrospectiveGlucoseDiscrepancies ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepanciesSummed: [",
                "* GlucoseChange(start, end, mg/dL)",
                (manager.runner.retrospectiveGlucoseDiscrepanciesSummed ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "glucoseMomentumEffect: \(manager.runner.glucoseMomentumEffect ?? [])",
                "retrospectiveGlucoseEffect: \(manager.runner.retrospectiveGlucoseEffect)",
                "recommendedAutomaticDose: \(String(describing: state.recommendedAutomaticDose))",
                "lastBolus: \(String(describing: manager.runner.lastRequestedBolus))",
                "lastLoopCompleted: \(String(describing: manager.lastLoopCompleted))",
                "basalDeliveryState: \(String(describing: manager.basalDeliveryState))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))",
                "insulinOnBoard: \(String(describing: manager.runner.insulinOnBoard))",
                "error: \(String(describing: state.error))",
                "overrideInUserDefaults: \(String(describing: UserDefaults.appGroup?.intentExtensionOverrideToSet))",
                "glucoseBasedApplicationFactorEnabled: \(UserDefaults.standard.glucoseBasedApplicationFactorEnabled)",
                "",
                String(reflecting: self.retrospectiveCorrection),
                "",
            ]

            self.glucoseStore.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")

                self.carbStore.generateDiagnosticReport { (report) in
                    entries.append(report)
                    entries.append("")

                    self.doseStore.generateDiagnosticReport { (report) in
                        entries.append(report)
                        entries.append("")

                        self.mealDetectionManager.generateDiagnosticReport { report in
                            entries.append(report)
                            entries.append("")

                            UNUserNotificationCenter.current().generateDiagnosticReport { (report) in
                                entries.append(report)
                                entries.append("")

                                #if os(iOS)
                                UIDevice.current.generateDiagnosticReport { (report) in
                                    entries.append(report)
                                    entries.append("")

                                    completion(entries.joined(separator: "\n"))
                                }
                                #else
                                completion(entries.joined(separator: "\n"))
                                #endif
                            }
                        }
                    }
                }
            }
        }
    }
}


extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(rawValue: "com.loopkit.Loop.LoopDataUpdated")
    static let LoopRunning = Notification.Name(rawValue: "com.loopkit.Loop.LoopRunning")
    static let LoopCompleted = Notification.Name(rawValue: "com.loopkit.Loop.LoopCompleted")
}

protocol LoopDataManagerDelegate: AnyObject {

    /// Informs the delegate that an immediate basal change is recommended
    func loopDataManager(_ manager: LoopDataManager, didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date), completion: @escaping (LoopError?) -> Void) -> Void

    /// Asks the delegate to round a recommended basal rate to a supported rate
    func roundBasalRate(unitsPerHour: Double) -> Double

    /// Asks the delegate to estimate the duration to deliver the bolus.
    func loopDataManager(_ manager: LoopDataManager, estimateBolusDuration bolusUnits: Double) -> TimeInterval?

    /// Asks the delegate to round a recommended bolus volume to a supported volume
    func roundBolusVolume(units: Double) -> Double

    /// The pump manager status, if one exists.
    var pumpManagerStatus: PumpManagerStatus? { get }

    /// The pump status highlight, if one exists.
    var pumpStatusHighlight: DeviceStatusHighlight? { get }

    /// The cgm manager status, if one exists.
    var cgmManagerStatus: CGMManagerStatus? { get }
}

extension ManualBolusRecommendationWithDate {
    init?(_ bolusRecommendationDate: (recommendation: ManualBolusRecommendation, date: Date)?) {
        guard let bolusRecommendationDate = bolusRecommendationDate else {
            return nil
        }
        self.init(recommendation: bolusRecommendationDate.recommendation, date: bolusRecommendationDate.date)
    }
}

// MARK: - LoopAlgorithmWarning → iOS LoopWarning bridge
//
// The runner uses the cross-platform `LoopAlgorithmWarning`; iOS preserves
// its existing rich `LoopWarning.issue` mapping by bridging through this
// 1:1 conversion in the delegate's `issueFor warning:` callback.
private extension LoopAlgorithmWarning {
    var iosLoopWarning: LoopWarning {
        switch self {
        case .fetchDataWarning(let detail):
            return .fetchDataWarning(detail.iosDetail)
        case .bolusInProgress:
            return .bolusInProgress
        }
    }
}

private extension LoopAlgorithmFetchDataWarningDetail {
    var iosDetail: FetchDataWarningDetail {
        switch self {
        case .glucoseSamples(let error):                       return .glucoseSamples(error: error)
        case .glucoseMomentumEffect(let error):                return .glucoseMomentumEffect(error: error)
        case .insulinEffect(let error):                        return .insulinEffect(error: error)
        case .insulinEffectIncludingPendingInsulin(let error): return .insulinEffectIncludingPendingInsulin(error: error)
        case .insulinCounteractionEffect(let error):           return .insulinCounteractionEffect(error: error)
        case .carbEffect(let error):                           return .carbEffect(error: error)
        case .carbsOnBoard(let error):                         return .carbsOnBoard(error: error)
        case .insulinOnBoard(let error):                       return .insulinOnBoard(error: error)
        case .retrospectiveGlucoseEffect(let error):           return .retrospectiveGlucoseEffect(error: error)
        }
    }
}

// MARK: - Simulated Core Data

extension LoopDataManager {
    func generateSimulatedHistoricalCoreData(completion: @escaping (Error?) -> Void) {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        guard let glucoseStore = glucoseStore as? GlucoseStore, let carbStore = carbStore as? CarbStore, let doseStore = doseStore as? DoseStore, let dosingDecisionStore = dosingDecisionStore as? DosingDecisionStore else {
            fatalError("Mock stores should not be used to generate simulated core data")
        }

        glucoseStore.generateSimulatedHistoricalGlucoseObjects() { error in
            guard error == nil else {
                completion(error)
                return
            }
            carbStore.generateSimulatedHistoricalCarbObjects() { error in
                guard error == nil else {
                    completion(error)
                    return
                }
                dosingDecisionStore.generateSimulatedHistoricalDosingDecisionObjects() { error in
                    guard error == nil else {
                        completion(error)
                        return
                    }
                    doseStore.generateSimulatedHistoricalPumpEvents(completion: completion)
                }
            }
        }
    }

    func purgeHistoricalCoreData(completion: @escaping (Error?) -> Void) {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        guard let glucoseStore = glucoseStore as? GlucoseStore, let carbStore = carbStore as? CarbStore, let doseStore = doseStore as? DoseStore, let dosingDecisionStore = dosingDecisionStore as? DosingDecisionStore else {
            fatalError("Mock stores should not be used to generate simulated core data")
        }

        doseStore.purgeHistoricalPumpEvents() { error in
            guard error == nil else {
                completion(error)
                return
            }
            dosingDecisionStore.purgeHistoricalDosingDecisionObjects() { error in
                guard error == nil else {
                    completion(error)
                    return
                }
                carbStore.purgeHistoricalCarbObjects() { error in
                    guard error == nil else {
                        completion(error)
                        return
                    }
                    glucoseStore.purgeHistoricalGlucoseObjects(completion: completion)
                }
            }
        }
    }
}

// MARK: - Therapy settings

extension LoopDataManager {
    public var therapySettings: TherapySettings {
        get {
            let settings = settings
            return TherapySettings(glucoseTargetRangeSchedule: settings.glucoseTargetRangeSchedule,
                            correctionRangeOverrides: CorrectionRangeOverrides(preMeal: settings.preMealTargetRange, workout: settings.legacyWorkoutTargetRange),
                            overridePresets: settings.overridePresets,
                            maximumBasalRatePerHour: settings.maximumBasalRatePerHour,
                            maximumBolus: settings.maximumBolus,
                            suspendThreshold: settings.suspendThreshold,
                            insulinSensitivitySchedule: settings.insulinSensitivitySchedule,
                            carbRatioSchedule: settings.carbRatioSchedule,
                            basalRateSchedule: settings.basalRateSchedule,
                            defaultRapidActingModel: settings.defaultRapidActingModel)
        }

        set {
            mutateSettings { settings in
                settings.defaultRapidActingModel = newValue.defaultRapidActingModel
                settings.insulinSensitivitySchedule = newValue.insulinSensitivitySchedule
                settings.carbRatioSchedule = newValue.carbRatioSchedule
                settings.basalRateSchedule = newValue.basalRateSchedule
                settings.glucoseTargetRangeSchedule = newValue.glucoseTargetRangeSchedule
                settings.preMealTargetRange = newValue.correctionRangeOverrides?.preMeal
                settings.legacyWorkoutTargetRange = newValue.correctionRangeOverrides?.workout
                settings.suspendThreshold = newValue.suspendThreshold
                settings.maximumBolus = newValue.maximumBolus
                settings.maximumBasalRatePerHour = newValue.maximumBasalRatePerHour
                settings.overridePresets = newValue.overridePresets ?? []
            }
        }
    }
}

// MARK: - Services manager delegate (overrides + carb actions)

extension LoopDataManager: ServicesManagerDelegate {

    //Overrides

    func enactOverride(name: String, duration: TemporaryScheduleOverride.Duration?, remoteAddress: String) async throws {

        guard let preset = settings.overridePresets.first(where: { $0.name == name }) else {
            throw EnactOverrideError.unknownPreset(name)
        }

        var remoteOverride = preset.createOverride(enactTrigger: .remote(remoteAddress))

        if let duration {
            remoteOverride.duration = duration
        }

        await enactOverride(remoteOverride)
    }


    func cancelCurrentOverride() async throws {
        await enactOverride(nil)
    }

    func enactOverride(_ override: TemporaryScheduleOverride?) async {
        mutateSettings { settings in settings.scheduleOverride = override }
    }

    enum EnactOverrideError: LocalizedError {

        case unknownPreset(String)

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let presetName):
                return String(format: NSLocalizedString("Unknown preset: %1$@", comment: "Override error description: unknown preset (1: preset name)."), presetName)
            }
        }
    }

    //Carb Entry

    func deliverCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws {

        let absorptionTime = absorptionTime ?? carbStore.defaultAbsorptionTimes.medium
        if absorptionTime < LoopConstants.minCarbAbsorptionTime || absorptionTime > LoopConstants.maxCarbAbsorptionTime {
            throw CarbActionError.invalidAbsorptionTime(absorptionTime)
        }

        guard amountInGrams > 0.0 else {
            throw CarbActionError.invalidCarbs
        }

        guard amountInGrams <= LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram()) else {
            throw CarbActionError.exceedsMaxCarbs
        }

        if let startDate = startDate {
            let maxStartDate = Date().addingTimeInterval(LoopConstants.maxCarbEntryFutureTime)
            let minStartDate = Date().addingTimeInterval(LoopConstants.maxCarbEntryPastTime)
            guard startDate <= maxStartDate  && startDate >= minStartDate else {
                throw CarbActionError.invalidStartDate(startDate)
            }
        }

        let quantity = HKQuantity(unit: .gram(), doubleValue: amountInGrams)
        let candidateCarbEntry = NewCarbEntry(quantity: quantity, startDate: startDate ?? Date(), foodType: foodType, absorptionTime: absorptionTime)

        let _ = try await devliverCarbEntry(candidateCarbEntry)
    }

    enum CarbActionError: LocalizedError {

        case invalidAbsorptionTime(TimeInterval)
        case invalidStartDate(Date)
        case exceedsMaxCarbs
        case invalidCarbs

        var errorDescription: String? {
            switch  self {
            case .exceedsMaxCarbs:
                return NSLocalizedString("Exceeds maximum allowed carbs", comment: "Carb error description: carbs exceed maximum amount.")
            case .invalidCarbs:
                return NSLocalizedString("Invalid carb amount", comment: "Carb error description: invalid carb amount.")
            case .invalidAbsorptionTime(let absorptionTime):
                let absorptionHoursFormatted = Self.numberFormatter.string(from: absorptionTime.hours) ?? ""
                return String(format: NSLocalizedString("Invalid absorption time: %1$@ hours", comment: "Carb error description: invalid absorption time. (1: Input duration in hours)."), absorptionHoursFormatted)
            case .invalidStartDate(let startDate):
                let startDateFormatted = Self.dateFormatter.string(from: startDate)
                return String(format: NSLocalizedString("Start time is out of range: %@", comment: "Carb error description: invalid start time is out of range."), startDateFormatted)
            }
        }

        static var numberFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }()

        static var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return formatter
        }()
    }

    //Can't add this concurrency wrapper method to LoopKit due to the minimum iOS version
    func devliverCarbEntry(_ carbEntry: NewCarbEntry) async throws -> StoredCarbEntry {
        return try await withCheckedThrowingContinuation { continuation in
            carbStore.addCarbEntry(carbEntry) { result in
                switch result {
                case .success(let storedCarbEntry):
                    continuation.resume(returning: storedCarbEntry)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}
