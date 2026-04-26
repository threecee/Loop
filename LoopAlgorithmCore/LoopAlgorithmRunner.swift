//
//  LoopAlgorithmRunner.swift
//  LoopAlgorithmCore
//
//  Cross-platform stateful runner that wraps LoopKit's LoopAlgorithm /
//  LoopMath / DoseMath / CarbMath primitives into a complete loop iteration.
//
//  iOS LoopDataManager and (future) WatchAlgorithmDriver each construct a
//  runner and implement LoopAlgorithmRunnerDelegate to handle the
//  platform-specific orchestration (LiveActivities, Widgets, NSNotifications
//  on iOS; reactive state stream on watchOS).
//
//  Phase 2.D: this file is type-checked + builds in LoopAlgorithmCore but no
//  caller is wired up. Phase 2.E rewires iOS LoopDataManager to delegate to
//  it.
//
//  IMPORTANT: the algorithm method bodies in this file are copied VERBATIM
//  from `Loop/Loop/Managers/LoopDataManager.swift`. The only edits are:
//    - replacing direct iOS calls (NotificationCenter.post, UIDevice,
//      UserDefaults.standard, WidgetCenter, MealDetectionManager,
//      AnalyticsServicesManager, LiveActivity) with delegate / provider
//      callbacks
//    - replacing iOS-only `LoopWarning` with the LAC-local `LoopAlgorithmWarning`
//    - access-modifier changes to expose the runner's public surface
//
//  Part of B.3.a — see:
//    docs/superpowers/specs/2026-04-26-b3a-watch-self-driving-design.md
//    docs/research/2026-04-26-loopalgorithmcore-extraction.md
//

import Foundation
import Combine
import HealthKit
import os
import LoopKit
import LoopCore

// MARK: - Cross-platform LoopWarning analog

/// Algorithm-side warning enum, mirrored from iOS-only `LoopWarning` so the
/// runner can describe data-fetch failures without depending on the iOS app
/// target. The conversion to `StoredDosingDecision.Issue` (which needs the
/// iOS-only `StoredDosingDecisionIssue` description helper) lives in iOS
/// LoopDataManager extensions.
public enum LoopAlgorithmFetchDataWarningDetail {
    case glucoseSamples(error: Error)
    case glucoseMomentumEffect(error: Error)
    case insulinEffect(error: Error)
    case insulinEffectIncludingPendingInsulin(error: Error)
    case insulinCounteractionEffect(error: Error)
    case carbEffect(error: Error)
    case carbsOnBoard(error: Error)
    case insulinOnBoard(error: Error)
    case retrospectiveGlucoseEffect(error: Error)
}

public enum LoopAlgorithmWarning {
    case fetchDataWarning(LoopAlgorithmFetchDataWarningDetail)
    case bolusInProgress
}

extension Locked where T == [LoopAlgorithmWarning] {
    func append(_ warning: LoopAlgorithmWarning) { mutate { $0.append(warning) } }
}

// MARK: - TimeInterval helpers
//
// LoopKit defines `TimeInterval.minutes(_:)` / `.hours(_:)` as `internal`, so
// LAC can't reach them. We re-declare module-private equivalents under the
// same names so the algorithm bodies — which were copied verbatim from
// LoopDataManager — keep working without textual changes.

extension TimeInterval {
    static func minutes(_ minutes: Double) -> TimeInterval { minutes * 60 }
    static func hours(_ hours: Double) -> TimeInterval { hours * 60 * 60 }
    init(minutes: Double) { self.init(minutes * 60) }
    init(hours: Double)   { self.init(hours * 60 * 60) }
    var minutes: Double { self / 60 }
    var hours: Double   { self / 3600 }
}

// MARK: - LoopSettings.enabledEffects (iOS-Loop's `enabledEffects` extension is iOS-only)
//
// The iOS extension reads `LoopConstants.retrospectiveCorrectionEnabled` which
// is hard-coded `true`; this LAC-local mirror just returns `.all` (the
// retrospection bit is always included).

extension LoopSettings {
    var loopAlgorithmCore_enabledEffects: PredictionInputEffect {
        PredictionInputEffect.all
    }
}

// MARK: - Inlined Data.hexadecimalString (LoopKit's matching extension is internal)

extension Data {
    var loopAlgorithmCore_hexadecimalString: String {
        let hexAlphabet = Array("0123456789abcdef".unicodeScalars)
        var s = ""
        s.reserveCapacity(count * 2)
        for byte in self {
            s.unicodeScalars.append(hexAlphabet[Int(byte / 16)])
            s.unicodeScalars.append(hexAlphabet[Int(byte % 16)])
        }
        return s
    }
}

// MARK: - Inlined Collection.partitioningIndex (LoopKit's matching extension is internal)

extension Collection where Index == Int {
    func loopAlgorithmCore_partitioningIndex(where belongsInSecondPartition: (Element) throws -> Bool) rethrows -> Index {
        var n = count
        var l = startIndex

        while n > 0 {
            let half = n / 2
            let mid = l + half
            if try belongsInSecondPartition(self[mid]) {
                n = half
            } else {
                l = mid + 1
                n -= half + 1
            }
        }
        return l
    }
}

// LoopError / LoopAlgorithmWarning → `StoredDosingDecision.Issue` conversion
// is delegated through `LoopAlgorithmRunnerDelegate.loopAlgorithmRunner(_:issueFor:)`
// so the host (iOS Loop) can plug in its richer mapping
// (`Loop/Extensions/LoopError+Issue.swift`, `Loop/Models/LoopWarning.swift`).
// The default protocol-extension implementation falls back to a minimal
// stringification so cross-platform callers (watch, tests) work without
// having to implement the hooks.

// MARK: - Update reason (algorithm-internal)

/// Why the runner is recomputing internal state.
public enum LoopAlgorithmUpdateReason: String {
    case loop
    case getLoopState
    case updateRemoteRecommendation
}

// MARK: - LoopAlgorithmRunner

/// Cross-platform algorithm runner. Owns the cached prediction effects, the
/// retrospective-correction model, and the loop-iteration entry points.
///
/// This is the file that holds the algorithm body verbatim from the iOS-only
/// `LoopDataManager`. Side effects that are platform-specific (notifications,
/// LiveActivity, Widgets, missed-meal UNNotification) are delegated through
/// `LoopAlgorithmRunnerDelegate`.
public final class LoopAlgorithmRunner {

    // MARK: Public collaborators

    public let loopLock = UnfairLock()

    public let carbStore: CarbStoreProtocol
    public let doseStore: DoseStoreProtocol
    public let dosingDecisionStore: DosingDecisionStoreProtocol
    public let glucoseStore: GlucoseStoreProtocol

    public let latestStoredSettingsProvider: LoopAlgorithmLatestStoredSettingsProvider
    public let controllerStatusProvider: LoopAlgorithmControllerStatusProvider?
    public let featureFlagProvider: LoopAlgorithmFeatureFlagProvider

    public weak var delegate: LoopAlgorithmRunnerDelegate?

    public let automaticDosingStatus: AutomaticDosingStatusBridge

    public let trustedTimeOffset: () -> TimeInterval
    public let now: () -> Date

    // MARK: Internal cached state

    private let logger = OSLogShim(category: "LoopAlgorithmRunner")

    private lazy var cancellables = Set<AnyCancellable>()

    private var timeBasedDoseApplicationFactor: Double = 1.0

    private(set) public var insulinOnBoard: InsulinValue?

    // MARK: Settings (thread-safe via Locked)

    private var lockedSettings: Locked<LoopSettings>

    public var settings: LoopSettings {
        lockedSettings.value
    }

    /// Override history; mutated by `mutateSettings` when a schedule override
    /// is applied. Public so the host can also feed it from external sources
    /// (Nightscout, watch sync).
    public let overrideHistory: TemporaryScheduleOverrideHistory

    @Published public private(set) var dosingEnabled: Bool

    // MARK: Locked pump state

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? {
        get { lockedBasalDeliveryState.value }
        set {
            self.logger.debug("Updating basalDeliveryState to \(String(describing: newValue))")
            lockedBasalDeliveryState.value = newValue
        }
    }
    private let lockedBasalDeliveryState: Locked<PumpManagerStatus.BasalDeliveryState?>

    public var pumpInsulinType: InsulinType? {
        get { lockedPumpInsulinType.value }
        set { lockedPumpInsulinType.value = newValue }
    }
    private let lockedPumpInsulinType: Locked<InsulinType?>

    public var lastLoopCompleted: Date? {
        get { lockedLastLoopCompleted.value }
        set { lockedLastLoopCompleted.value = newValue }
    }
    private let lockedLastLoopCompleted: Locked<Date?>

    // MARK: Dispatch queue (algorithm serialization)

    fileprivate let dataAccessQueue: DispatchQueue =
        DispatchQueue(label: "com.loopkit.LoopAlgorithmCore.LoopAlgorithmRunner.dataAccessQueue", qos: .utility)

    // MARK: Cached effect timelines

    private(set) public var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }

    private(set) public var insulinEffect: [GlucoseEffect]?

    private var insulinEffectIncludingPendingInsulin: [GlucoseEffect]? {
        didSet {
            predictedGlucoseIncludingPendingInsulin = nil
        }
    }

    private(set) public var glucoseMomentumEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }

    private(set) public var retrospectiveGlucoseEffect: [GlucoseEffect] = [] {
        didSet {
            predictedGlucose = nil
        }
    }

    /// When combining retrospective glucose discrepancies, extend the window
    /// slightly as a buffer.
    private let retrospectiveCorrectionGroupingIntervalMultiplier = 1.01

    private(set) public var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(
                of: LoopMath.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier
            )
        }
    }

    private(set) public var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?

    private var suspendInsulinDeliveryEffect: [GlucoseEffect] = []

    private(set) public var predictedGlucose: [PredictedGlucoseValue]? {
        didSet {
            recommendedAutomaticDose = nil
            predictedGlucoseIncludingPendingInsulin = nil
        }
    }

    private(set) public var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]?

    private(set) public var recentCarbEntries: [StoredCarbEntry]?

    private(set) public var recommendedAutomaticDose: (recommendation: AutomaticDoseRecommendation, date: Date)?

    private(set) public var carbsOnBoard: CarbValue?

    public internal(set) var lastRequestedBolus: DoseEntry?

    private(set) public var lastLoopError: LoopError?

    /// A timeline of average velocity of glucose change counteracting
    /// predicted insulin effects.
    private(set) public var insulinCounteractionEffects: [GlucoseEffectVelocity] = [] {
        didSet {
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    // Confined to dataAccessQueue
    private var lastIntegralRetrospectiveCorrectionEnabled: Bool?
    private var cachedRetrospectiveCorrection: RetrospectiveCorrection?

    public var retrospectiveCorrection: RetrospectiveCorrection {
        let currentIntegralRetrospectiveCorrectionEnabled = featureFlagProvider.integralRetrospectiveCorrectionEnabled

        if lastIntegralRetrospectiveCorrectionEnabled != currentIntegralRetrospectiveCorrectionEnabled || cachedRetrospectiveCorrection == nil {
            lastIntegralRetrospectiveCorrectionEnabled = currentIntegralRetrospectiveCorrectionEnabled
            if currentIntegralRetrospectiveCorrectionEnabled {
                cachedRetrospectiveCorrection = IntegralRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
            } else {
                cachedRetrospectiveCorrection = StandardRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
            }
        }

        return cachedRetrospectiveCorrection!
    }

    public func clearCachedInsulinEffects() {
        insulinEffect = nil
        insulinEffectIncludingPendingInsulin = nil
        predictedGlucose = nil
    }

    /// Set to `true` whenever the cached remote recommendation may be stale;
    /// `updateRemoteRecommendation()` consumes it.
    public var remoteRecommendationNeedsUpdating: Bool = false

    // MARK: Init

    public init(
        lastLoopCompleted: Date?,
        basalDeliveryState: PumpManagerStatus.BasalDeliveryState?,
        settings: LoopSettings,
        overrideHistory: TemporaryScheduleOverrideHistory,
        doseStore: DoseStoreProtocol,
        glucoseStore: GlucoseStoreProtocol,
        carbStore: CarbStoreProtocol,
        dosingDecisionStore: DosingDecisionStoreProtocol,
        latestStoredSettingsProvider: LoopAlgorithmLatestStoredSettingsProvider,
        controllerStatusProvider: LoopAlgorithmControllerStatusProvider?,
        featureFlagProvider: LoopAlgorithmFeatureFlagProvider,
        automaticDosingStatus: AutomaticDosingStatusBridge,
        pumpInsulinType: InsulinType?,
        trustedTimeOffset: @escaping () -> TimeInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        self.lockedLastLoopCompleted = Locked(lastLoopCompleted)
        self.lockedBasalDeliveryState = Locked(basalDeliveryState)
        self.lockedSettings = Locked(settings)
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
        self.controllerStatusProvider = controllerStatusProvider
        self.featureFlagProvider = featureFlagProvider

        self.lockedPumpInsulinType = Locked(pumpInsulinType)
        self.automaticDosingStatus = automaticDosingStatus
        self.trustedTimeOffset = trustedTimeOffset

        // The original LoopDataManager wires three NotificationCenter
        // observers (carbEntriesDidChange, glucoseSamplesDidChange, doseStore
        // changes) here. Those remain on the iOS LoopDataManager shim, which
        // forwards into the runner via `handleCarbEntriesDidChange()`,
        // `handleGlucoseSamplesDidChange()`, and `handleDoseStoreDidChange()`.
        //
        // Same for the `automaticDosingStatus.$automaticDosingEnabled` Combine
        // sink (cancels temp basal when closed-loop mode flips off): keeping
        // the subscription on the iOS shim avoids cross-platform Combine
        // ordering surprises.
    }

    // MARK: - Notification observer hand-offs (B.3.a Phase 2.E)
    //
    // The iOS shim wires NotificationCenter observers and forwards them to
    // these methods so the runner owns the cache-invalidation + notify
    // semantics that used to live inline in those observers.

    public func handleCarbEntriesDidChange() {
        dataAccessQueue.async { [weak self] in
            guard let self = self else { return }
            self.logger.default("Received notification of carb entries changing")
            self.carbEffect = nil
            self.carbsOnBoard = nil
            self.recentCarbEntries = nil
            self.remoteRecommendationNeedsUpdating = true
            self.notify(forChange: .carbs)
        }
    }

    public func handleGlucoseSamplesDidChange() {
        dataAccessQueue.async { [weak self] in
            guard let self = self else { return }
            self.logger.default("Received notification of glucose samples changing")
            self.glucoseMomentumEffect = nil
            self.remoteRecommendationNeedsUpdating = true
            self.notify(forChange: .glucose)
        }
    }

    public func handleDoseStoreDidChange() {
        dataAccessQueue.async { [weak self] in
            guard let self = self else { return }
            self.logger.default("Received notification of dosing changing")
            self.clearCachedInsulinEffects()
            self.remoteRecommendationNeedsUpdating = true
            self.notify(forChange: .insulin)
        }
    }

    // MARK: - Data-access queue helpers (B.3.a Phase 2.E)
    //
    // The iOS shim's LoopStateView needs to read cached state on the runner's
    // serial queue so concurrent loop iterations don't corrupt the snapshot.
    // These helpers expose the queue without exposing the queue object
    // itself, keeping the runner's internal queueing strategy private.

    public func runOnDataAccessQueue(_ work: @escaping () -> Void) {
        dataAccessQueue.async { work() }
    }

    public func dispatchPrecondition_assertOnDataAccessQueue() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
    }

    /// Runs `update(for: .getLoopState)` on the data-access queue
    /// synchronously. Used by `LoopDataManager.getLoopState`.
    public func runUpdateForGetLoopState() -> LoopError? {
        dispatchPrecondition_assertOnDataAccessQueue()
        let (_, updateError) = self.update(for: .getLoopState)
        return updateError
    }

    // MARK: - Settings mutation

    /// Apply a settings change. Diffs the new settings against the old, applies
    /// algorithm-side state mutations (cache invalidations, schedule pushes),
    /// then calls the delegate with a `LoopAlgorithmSettingsChangeImpact` so
    /// the host can fan out to LiveActivity / analytics / preset observers.
    public func mutateSettings(_ changes: (_ settings: inout LoopSettings) -> Void) {
        var oldValue: LoopSettings!
        let newValue = lockedSettings.mutate { settings in
            oldValue = settings
            changes(&settings)
        }

        guard oldValue != newValue else {
            return
        }

        var invalidateCachedEffects = false

        dosingEnabled = newValue.dosingEnabled

        let preMealOverrideChanged = newValue.preMealOverride != oldValue.preMealOverride
        if preMealOverrideChanged {
            // The prediction isn't actually invalid, but a target range change
            // requires recomputing recommended doses
            predictedGlucose = nil
        }

        let scheduleOverrideChanged = newValue.scheduleOverride != oldValue.scheduleOverride
        if scheduleOverrideChanged {
            overrideHistory.recordOverride(settings.scheduleOverride)
            // Invalidate cached effects affected by the override
            invalidateCachedEffects = true
        }

        let insulinSensitivityScheduleChanged = newValue.insulinSensitivitySchedule != oldValue.insulinSensitivitySchedule
        if insulinSensitivityScheduleChanged {
            carbStore.insulinSensitivitySchedule = newValue.insulinSensitivitySchedule
            doseStore.insulinSensitivitySchedule = newValue.insulinSensitivitySchedule
            invalidateCachedEffects = true
        }

        // `basalRateScheduleChanged` flags whether downstream analytics
        // should fire — matches the original iOS LoopDataManager semantics:
        // only when BOTH schedules are non-nil AND their items differ.
        // (Adding or removing the schedule entirely doesn't trigger
        // analytics; only an item-level change does.)
        let basalRateScheduleChanged: Bool
        if newValue.basalRateSchedule != oldValue.basalRateSchedule {
            doseStore.basalProfile = newValue.basalRateSchedule
            if let n = newValue.basalRateSchedule, let o = oldValue.basalRateSchedule, n.items != o.items {
                basalRateScheduleChanged = true
            } else {
                basalRateScheduleChanged = false
            }
        } else {
            basalRateScheduleChanged = false
        }

        let carbRatioScheduleChanged = newValue.carbRatioSchedule != oldValue.carbRatioSchedule
        if carbRatioScheduleChanged {
            carbStore.carbRatioSchedule = newValue.carbRatioSchedule
            invalidateCachedEffects = true
        }

        let insulinModelChanged = newValue.defaultRapidActingModel != oldValue.defaultRapidActingModel
        if insulinModelChanged {
            // Algorithm-side: just invalidate the effect cache. The iOS shim's
            // `settingsDidChange` delegate impl is responsible for swapping
            // `doseStore.insulinModelProvider` based on the
            // adultChildInsulinModelSelectionEnabled feature flag (which lives
            // in Loop, not LAC).
            invalidateCachedEffects = true
        }

        let maximumBolusChanged = newValue.maximumBolus != oldValue.maximumBolus

        if invalidateCachedEffects {
            dataAccessQueue.async {
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.clearCachedInsulinEffects()
            }
        }

        let impact = LoopAlgorithmSettingsChangeImpact(
            oldSettings: oldValue,
            newSettings: newValue,
            preMealOverrideChanged: preMealOverrideChanged,
            scheduleOverrideChanged: scheduleOverrideChanged,
            insulinSensitivityScheduleChanged: insulinSensitivityScheduleChanged,
            basalRateScheduleChanged: basalRateScheduleChanged,
            carbRatioScheduleChanged: carbRatioScheduleChanged,
            insulinModelChanged: insulinModelChanged,
            maximumBolusChanged: maximumBolusChanged
        )

        notify(forChange: .preferences)
        delegate?.loopAlgorithmRunner(self, settingsDidChange: impact)
    }

    // MARK: - Schedule accessors

    /// The basal rate schedule, applying recent overrides relative to the current moment in time.
    public var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        return doseStore.basalProfileApplyingOverrideHistory
    }

    /// The carb ratio schedule, applying recent overrides relative to the current moment in time.
    public var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        return carbStore.carbRatioScheduleApplyingOverrideHistory
    }

    /// The insulin sensitivity schedule, applying recent overrides relative to the current moment in time.
    public var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        return carbStore.insulinSensitivityScheduleApplyingOverrideHistory
    }

    /// Sets a new time zone for a the schedule-based settings
    public func setScheduleTimeZone(_ timeZone: TimeZone) {
        self.mutateSettings { settings in
            settings.basalRateSchedule?.timeZone = timeZone
            settings.carbRatioSchedule?.timeZone = timeZone
            settings.insulinSensitivitySchedule?.timeZone = timeZone
            settings.glucoseTargetRangeSchedule?.timeZone = timeZone
        }
    }

    // MARK: - Loop completion / error bookkeeping

    private func loopDidComplete(date: Date, dosingDecision: StoredDosingDecision, duration: TimeInterval) {
        logger.default("Loop completed successfully.")
        lastLoopCompleted = date
        dosingDecisionStore.storeDosingDecision(dosingDecision) {}
        delegate?.loopAlgorithmRunner(self, loopDidComplete: date, duration: duration)
    }

    private func loopDidError(date: Date, error: LoopError, dosingDecision: StoredDosingDecision, duration: TimeInterval) {
        logger.error("Loop did error: \(String(describing: error))")
        lastLoopError = error
        var dosingDecisionWithError = dosingDecision
        appendError(error, to: &dosingDecisionWithError)
        dosingDecisionStore.storeDosingDecision(dosingDecisionWithError) {}
        delegate?.loopAlgorithmRunner(self, loopDidError: error, duration: duration)
    }

    // MARK: - Remote recommendation

    public func updateRemoteRecommendation() {
        dataAccessQueue.async {
            if self.remoteRecommendationNeedsUpdating {
                var (dosingDecision, updateError) = self.update(for: .updateRemoteRecommendation)

                if let error = updateError {
                    self.logger.error("Error updating manual bolus recommendation: \(String(describing: error))")
                } else {
                    do {
                        if let predictedGlucoseIncludingPendingInsulin = self.predictedGlucoseIncludingPendingInsulin,
                           let manualBolusRecommendation = try self.recommendManualBolus(forPrediction: predictedGlucoseIncludingPendingInsulin, consideringPotentialCarbEntry: nil)
                        {
                            dosingDecision.manualBolusRecommendation = ManualBolusRecommendationWithDate(recommendation: manualBolusRecommendation, date: Date())
                            self.logger.debug("Manual bolus rec = \(String(describing: dosingDecision.manualBolusRecommendation))")
                            self.dosingDecisionStore.storeDosingDecision(dosingDecision) {}
                        }
                    } catch {
                        self.logger.error("Error updating manual bolus recommendation: \(String(describing: error))")
                    }
                }
                self.remoteRecommendationNeedsUpdating = false
            }
        }
    }

    // MARK: - Intake

    /// Adds and stores glucose samples
    public func addGlucoseSamples(
        _ samples: [NewGlucoseSample],
        completion: ((_ result: Swift.Result<[StoredGlucoseSample], Error>) -> Void)? = nil
    ) {
        glucoseStore.addGlucoseSamples(samples) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let samples):
                    if let endDate = samples.sorted(by: { $0.startDate < $1.startDate }).first?.startDate {
                        // Prune back any counteraction effects for recomputation
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filter { $0.endDate < endDate }
                    }

                    completion?(.success(samples))
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Take actions to address how insulin is delivered when the CGM data is unreliable.
    /// An active high temp basal (greater than the basal schedule) is cancelled when the CGM data is unreliable.
    public func receivedUnreliableCGMReading() {
        guard case .tempBasal(let tempBasal) = basalDeliveryState,
              let scheduledBasalRate = settings.basalRateSchedule?.value(at: now()),
              tempBasal.unitsPerHour > scheduledBasalRate else
        {
            return
        }

        // Cancel active high temp basal
        cancelActiveTempBasal(for: .unreliableCGMData)
    }

    public enum CancelActiveTempBasalReason: String {
        case automaticDosingDisabled
        case unreliableCGMData
        case maximumBasalRateChanged
    }

    /// Cancel the active temp basal if it was automatically issued
    public func cancelActiveTempBasal(for reason: CancelActiveTempBasalReason) {
        guard case .tempBasal(let dose) = basalDeliveryState, (dose.automatic ?? true) else { return }

        dataAccessQueue.async {
            self.cancelActiveTempBasal(for: reason, completion: nil)
        }
    }

    private func cancelActiveTempBasal(for reason: CancelActiveTempBasalReason, completion: ((Error?) -> Void)?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let recommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        recommendedAutomaticDose = (recommendation: recommendation, date: now())

        var dosingDecision = StoredDosingDecision(reason: reason.rawValue)
        dosingDecision.settings = StoredDosingDecision.Settings(latestStoredSettingsProvider.latestSettings)
        dosingDecision.controllerStatus = controllerStatusProvider?.controllerStatus
        dosingDecision.automaticDoseRecommendation = recommendation

        let error = enactRecommendedAutomaticDose()

        dosingDecision.pumpManagerStatus = delegate?.pumpManagerStatusForRunner
        dosingDecision.cgmManagerStatus = delegate?.cgmManagerStatusForRunner
        dosingDecision.lastReservoirValue = StoredDosingDecision.LastReservoirValue(doseStore.lastReservoirValue)

        if let error = error {
            appendError(error, to: &dosingDecision)
        }
        self.dosingDecisionStore.storeDosingDecision(dosingDecision) {}

        // Didn't actually run a loop, but this is similar to a loop() in that the automatic dosing was updated.
        self.notify(forChange: .loopFinished)
        completion?(error)
    }

    /// Adds and stores carb data, and recommends a bolus if needed.
    public func addCarbEntry(_ carbEntry: NewCarbEntry, replacing replacingEntry: StoredCarbEntry? = nil, completion: @escaping (_ result: Result<StoredCarbEntry>) -> Void) {
        let addCompletion: (CarbStoreResult<StoredCarbEntry>) -> Void = { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let storedCarbEntry):
                    // Remove the active pre-meal target override
                    self.mutateSettings { settings in
                        settings.clearOverride(matching: .preMeal)
                    }

                    self.carbEffect = nil
                    self.carbsOnBoard = nil
                    completion(.success(storedCarbEntry))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, completion: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, completion: addCompletion)
        }
    }

    public func deleteCarbEntry(_ oldEntry: StoredCarbEntry, completion: @escaping (_ result: CarbStoreResult<Bool>) -> Void) {
        carbStore.deleteCarbEntry(oldEntry) { result in
            completion(result)
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    public func addRequestedBolus(_ dose: DoseEntry, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.logger.debug("addRequestedBolus")
            self.lastRequestedBolus = dose
            self.notify(forChange: .insulin)

            completion?()
        }
    }

    /// Notifies the manager that the bolus is confirmed, but not fully delivered.
    public func bolusConfirmed(completion: (() -> Void)?) {
        self.dataAccessQueue.async {
            self.logger.debug("bolusConfirmed")
            self.lastRequestedBolus = nil
            self.recommendedAutomaticDose = nil
            self.clearCachedInsulinEffects()
            self.notify(forChange: .insulin)

            completion?()
        }
    }

    /// Notifies the manager that the bolus failed.
    public func bolusRequestFailed(_ error: Error, completion: (() -> Void)?) {
        self.dataAccessQueue.async {
            self.logger.debug("bolusRequestFailed")
            self.lastRequestedBolus = nil
            self.clearCachedInsulinEffects()
            self.notify(forChange: .insulin)

            completion?()
        }
    }

    /// Logs a new external bolus insulin dose in the DoseStore and HealthKit.
    public func addManuallyEnteredDose(startDate: Date, units: Double, insulinType: InsulinType? = nil) {
        let syncIdentifier = Data(UUID().uuidString.utf8).loopAlgorithmCore_hexadecimalString
        let dose = DoseEntry(type: .bolus, startDate: startDate, value: units, unit: .units, syncIdentifier: syncIdentifier, insulinType: insulinType, manuallyEntered: true)

        doseStore.addDoses([dose], from: nil) { (error) in
            if error == nil {
                self.recommendedAutomaticDose = nil
                self.clearCachedInsulinEffects()
                self.notify(forChange: .insulin)
            }
        }
    }

    /// Adds and stores a pump reservoir volume.
    public func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        doseStore.addReservoirValue(units, at: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.clearCachedInsulinEffects()

                    if let newDoseStartDate = previousValue?.startDate {
                        // Prune back any counteraction effects for recomputation, after the effect delay
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(nil, newDoseStartDate.addingTimeInterval(.minutes(10)))
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else {
                assertionFailure()
            }
        }
    }

    public func storeManualBolusDosingDecision(_ bolusDosingDecision: BolusDosingDecision, withDate date: Date) {
        let controllerStatus = controllerStatusProvider?.controllerStatus
        let dosingDecision = StoredDosingDecision(date: date,
                                                  reason: bolusDosingDecision.reason.rawValue,
                                                  settings: StoredDosingDecision.Settings(latestStoredSettingsProvider.latestSettings),
                                                  scheduleOverride: bolusDosingDecision.scheduleOverride,
                                                  controllerStatus: controllerStatus,
                                                  pumpManagerStatus: delegate?.pumpManagerStatusForRunner,
                                                  cgmManagerStatus: delegate?.cgmManagerStatusForRunner,
                                                  lastReservoirValue: StoredDosingDecision.LastReservoirValue(doseStore.lastReservoirValue),
                                                  historicalGlucose: bolusDosingDecision.historicalGlucose,
                                                  originalCarbEntry: bolusDosingDecision.originalCarbEntry,
                                                  carbEntry: bolusDosingDecision.carbEntry,
                                                  manualGlucoseSample: bolusDosingDecision.manualGlucoseSample,
                                                  carbsOnBoard: bolusDosingDecision.carbsOnBoard,
                                                  insulinOnBoard: bolusDosingDecision.insulinOnBoard,
                                                  glucoseTargetRangeSchedule: bolusDosingDecision.glucoseTargetRangeSchedule,
                                                  predictedGlucose: bolusDosingDecision.predictedGlucose,
                                                  manualBolusRecommendation: bolusDosingDecision.manualBolusRecommendation,
                                                  manualBolusRequested: bolusDosingDecision.manualBolusRequested)
        dosingDecisionStore.storeDosingDecision(dosingDecision) {}
    }

    // MARK: - Loop entry points

    /// Runs the "loop" — analyzes current data and recommends an adjustment to the current temporary basal rate.
    public func loop() {
        if let lastLoopCompleted, Date().timeIntervalSince(lastLoopCompleted) < .minutes(2) {
            print("Looping too fast!")
        }

        let available = loopLock.withLockIfAvailable {
            loopInternal()
            return true
        }
        if available == nil {
            print("Loop attempted while already looping!")
        }
    }

    public func loopInternal() {
        dataAccessQueue.async {

            // If time was changed to future time, and a loop completed, then time was fixed, lastLoopCompleted will prevent looping
            // until the future loop time passes. Fix that here.
            if let lastLoopCompleted = self.lastLoopCompleted, Date() < lastLoopCompleted, self.trustedTimeOffset() == 0 {
                self.logger.error("Detected future lastLoopCompleted. Restoring.")
                self.lastLoopCompleted = Date()
            }

            // Partial application factor assumes 5 minute intervals. If our looping intervals are shorter, then this will be adjusted
            self.timeBasedDoseApplicationFactor = 1.0
            if let lastLoopCompleted = self.lastLoopCompleted {
                let timeSinceLastLoop = max(0, Date().timeIntervalSince(lastLoopCompleted))
                self.timeBasedDoseApplicationFactor = min(1, timeSinceLastLoop / TimeInterval.minutes(5))
                self.logger.default("Looping with timeBasedDoseApplicationFactor = \(self.timeBasedDoseApplicationFactor)")
            }

            self.logger.default("Loop running")
            self.delegate?.loopAlgorithmRunnerDidStartLoop(self)

            self.lastLoopError = nil
            let startDate = self.now()

            var (dosingDecision, error) = self.update(for: .loop)

            if error == nil, self.automaticDosingStatus.automaticDosingEnabled == true {
                error = self.enactRecommendedAutomaticDose()
            } else {
                self.logger.default("Not adjusting dosing during open loop.")
            }

            self.finishLoop(startDate: startDate, dosingDecision: dosingDecision, error: error)
        }
    }

    private func finishLoop(startDate: Date, dosingDecision: StoredDosingDecision, error: LoopError? = nil) {
        let date = now()
        let duration = date.timeIntervalSince(startDate)

        if let error = error {
            loopDidError(date: date, error: error, dosingDecision: dosingDecision, duration: duration)
        } else {
            loopDidComplete(date: date, dosingDecision: dosingDecision, duration: duration)
        }

        logger.default("Loop ended")
        notify(forChange: .loopFinished)

        if featureFlagProvider.missedMealNotificationsEnabled {
            // MissedMealSettings.maxRecency = 2 hours; inlined since the type is iOS-Loop-only.
            let samplesStart = now().addingTimeInterval(-TimeInterval(hours: 2))
            carbStore.getGlucoseEffects(start: samplesStart, end: now(), effectVelocities: insulinCounteractionEffects) { [weak self] result in
                guard
                    let self = self,
                    case .success((_, let carbEffects)) = result
                else {
                    if case .failure(let error) = result {
                        self?.logger.error("Failed to fetch glucose effects to check for missed meal: \(String(describing: error))")
                    }
                    return
                }

                self.glucoseStore.getGlucoseSamples(start: samplesStart, end: self.now()) { [weak self] result in
                    guard
                        let self = self,
                        case .success(let glucoseSamples) = result
                    else {
                        if case .failure(let error) = result {
                            self?.logger.error("Failed to fetch glucose samples to check for missed meal: \(String(describing: error))")
                        }
                        return
                    }

                    self.delegate?.loopAlgorithmRunner(
                        self,
                        checkMissedMealWithGlucoseSamples: glucoseSamples,
                        insulinCounteractionEffects: self.insulinCounteractionEffects,
                        carbEffects: carbEffects,
                        pendingAutobolusUnits: self.recommendedAutomaticDose?.recommendation.bolusUnits
                    )
                }
            }
        }

        delegate?.loopAlgorithmRunnerDidFinishLoop(self)
        updateRemoteRecommendation()
    }

    fileprivate func update(for reason: LoopAlgorithmUpdateReason) -> (StoredDosingDecision, LoopError?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        var dosingDecision = StoredDosingDecision(reason: reason.rawValue)
        let latestSettings = latestStoredSettingsProvider.latestSettings
        dosingDecision.settings = StoredDosingDecision.Settings(latestSettings)
        dosingDecision.scheduleOverride = latestSettings.scheduleOverride
        dosingDecision.controllerStatus = controllerStatusProvider?.controllerStatus
        dosingDecision.pumpManagerStatus = delegate?.pumpManagerStatusForRunner
        if let pumpStatusHighlight = delegate?.pumpStatusHighlightForRunner {
            dosingDecision.pumpStatusHighlight = StoredDosingDecision.StoredDeviceHighlight(
                localizedMessage: pumpStatusHighlight.localizedMessage,
                imageName: pumpStatusHighlight.imageName,
                state: pumpStatusHighlight.state)
        }
        dosingDecision.cgmManagerStatus = delegate?.cgmManagerStatusForRunner
        dosingDecision.lastReservoirValue = StoredDosingDecision.LastReservoirValue(doseStore.lastReservoirValue)

        let warnings = Locked<[LoopAlgorithmWarning]>([])

        let updateGroup = DispatchGroup()

        let historicalGlucoseStartDate = Date(timeInterval: -LoopCoreConstants.dosingDecisionHistoricalGlucoseInterval, since: now())
        let inputDataRecencyStartDate = Date(timeInterval: -LoopCoreConstants.inputDataRecencyInterval, since: now())

        // Fetch glucose effects as far back as we want to make retroactive analysis and historical glucose for dosing decision
        var historicalGlucose: [HistoricalGlucoseValue]?
        var latestGlucoseDate: Date?
        updateGroup.enter()
        glucoseStore.getGlucoseSamples(start: min(historicalGlucoseStartDate, inputDataRecencyStartDate), end: nil) { (result) in
            switch result {
            case .failure(let error):
                self.logger.error("Failure getting glucose samples: \(String(describing: error))")
                latestGlucoseDate = nil
                warnings.append(.fetchDataWarning(.glucoseSamples(error: error)))
            case .success(let samples):
                historicalGlucose = samples.filter { $0.startDate >= historicalGlucoseStartDate }.map { HistoricalGlucoseValue(startDate: $0.startDate, quantity: $0.quantity) }
                latestGlucoseDate = samples.last?.startDate
            }
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)

        guard let lastGlucoseDate = latestGlucoseDate else {
            appendWarnings(warnings.value, to: &dosingDecision)
            appendError(LoopError.missingDataError(.glucose), to: &dosingDecision)
            return (dosingDecision, .missingDataError(.glucose))
        }

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-type(of: retrospectiveCorrection).retrospectionInterval)

        let earliestEffectDate = Date(timeInterval: .hours(-24), since: now())
        let nextCounteractionEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
        let insulinEffectStartDate = nextCounteractionEffectDate.addingTimeInterval(.minutes(-5))

        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            glucoseStore.getRecentMomentumEffect(for: now()) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("Failure getting recent momentum effect: \(String(describing: error))")
                    self.glucoseMomentumEffect = nil
                    warnings.append(.fetchDataWarning(.glucoseMomentumEffect(error: error)))
                case .success(let effects):
                    self.glucoseMomentumEffect = effects
                }
                updateGroup.leave()
            }
        }

        if insulinEffect == nil || insulinEffect?.first?.startDate ?? .distantFuture > insulinEffectStartDate {
            self.logger.debug("Recomputing insulin effects")
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: insulinEffectStartDate, end: nil, basalDosingEnd: now()) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("Could not fetch insulin effects: \(error.localizedDescription)")
                    self.insulinEffect = nil
                    warnings.append(.fetchDataWarning(.insulinEffect(error: error)))
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }

        if insulinEffectIncludingPendingInsulin == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: insulinEffectStartDate, end: nil, basalDosingEnd: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("Could not fetch insulin effects including pending insulin: \(error.localizedDescription)")
                    self.insulinEffectIncludingPendingInsulin = nil
                    warnings.append(.fetchDataWarning(.insulinEffectIncludingPendingInsulin(error: error)))
                case .success(let effects):
                    self.insulinEffectIncludingPendingInsulin = effects
                }

                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if nextCounteractionEffectDate < lastGlucoseDate, let insulinEffect = insulinEffect {
            updateGroup.enter()
            self.logger.debug("Fetching counteraction effects after \(String(describing: nextCounteractionEffectDate))")
            glucoseStore.getCounteractionEffects(start: nextCounteractionEffectDate, end: nil, to: insulinEffect) { (result) in
                switch result {
                case .failure(let error):
                    self.logger.error("Failure getting counteraction effects: \(String(describing: error))")
                    warnings.append(.fetchDataWarning(.insulinCounteractionEffect(error: error)))
                case .success(let velocities):
                    self.insulinCounteractionEffects.append(contentsOf: velocities)
                }
                self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)

                updateGroup.leave()
            }

            _ = updateGroup.wait(timeout: .distantFuture)
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart, end: nil,
                effectVelocities: insulinCounteractionEffects
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error("\(String(describing: error))")
                    self.carbEffect = nil
                    self.recentCarbEntries = nil
                    warnings.append(.fetchDataWarning(.carbEffect(error: error)))
                case .success(let (entries, effects)):
                    self.carbEffect = effects
                    self.recentCarbEntries = entries
                }

                updateGroup.leave()
            }
        }

        if carbsOnBoard == nil {
            updateGroup.enter()
            carbStore.carbsOnBoard(at: now(), effectVelocities: insulinCounteractionEffects) { (result) in
                switch result {
                case .failure(let error):
                    switch error {
                    case .noData:
                        // when there is no data, carbs on board is set to 0
                        self.carbsOnBoard = CarbValue(startDate: Date(), value: 0)
                    default:
                        self.carbsOnBoard = nil
                        warnings.append(.fetchDataWarning(.carbsOnBoard(error: error)))
                    }
                case .success(let value):
                    self.carbsOnBoard = value
                }
                updateGroup.leave()
            }
        }
        updateGroup.enter()
        doseStore.insulinOnBoard(at: now()) { result in
            switch result {
            case .failure(let error):
                warnings.append(.fetchDataWarning(.insulinOnBoard(error: error)))
            case .success(let insulinValue):
                self.insulinOnBoard = insulinValue
            }
            updateGroup.leave()
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if retrospectiveGlucoseDiscrepancies == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch let error {
                logger.error("\(String(describing: error))")
                warnings.append(.fetchDataWarning(.retrospectiveGlucoseEffect(error: error)))
            }
        }

        do {
            try updateSuspendInsulinDeliveryEffect()
        } catch let error {
            logger.error("\(String(describing: error))")
        }

        // Append warnings via the delegate's issue-conversion hook so the host
        // (iOS) can substitute its rich `LoopWarning.issue` mapping. The
        // default delegate impl falls back to a minimal stringification.
        appendWarnings(warnings.value, to: &dosingDecision)

        dosingDecision.date = now()
        dosingDecision.historicalGlucose = historicalGlucose
        dosingDecision.carbsOnBoard = carbsOnBoard
        dosingDecision.insulinOnBoard = self.insulinOnBoard
        dosingDecision.glucoseTargetRangeSchedule = settings.effectiveGlucoseTargetRangeSchedule()

        // These will be updated by updatePredictedGlucoseAndRecommendedDose, if possible
        dosingDecision.predictedGlucose = predictedGlucoseIncludingPendingInsulin
        dosingDecision.automaticDoseRecommendation = recommendedAutomaticDose?.recommendation

        // If the glucose prediction hasn't changed, then nothing has changed, so just use pre-existing recommendations
        guard predictedGlucose == nil else {

            // If we still have a bolus in progress, then warn (unlikely, but possible if device comms fail)
            if lastRequestedBolus != nil, dosingDecision.automaticDoseRecommendation == nil, dosingDecision.manualBolusRecommendation == nil {
                appendWarning(.bolusInProgress, to: &dosingDecision)
            }

            return (dosingDecision, nil)
        }

        return updatePredictedGlucoseAndRecommendedDose(with: dosingDecision)
    }

    private func notify(forChange context: LoopAlgorithmUpdateContext) {
        delegate?.loopAlgorithmRunner(self, didChange: context)
    }

    // MARK: - Issue conversion (delegate-routed with fallback)

    private func issue(for error: LoopError) -> StoredDosingDecision.Issue {
        if let delegate = delegate {
            return delegate.loopAlgorithmRunner(self, issueFor: error)
        }
        return StoredDosingDecision.Issue(id: String(describing: error))
    }

    private func issue(for warning: LoopAlgorithmWarning) -> StoredDosingDecision.Issue {
        if let delegate = delegate {
            return delegate.loopAlgorithmRunner(self, issueFor: warning)
        }
        return StoredDosingDecision.Issue(id: String(describing: warning))
    }

    fileprivate func appendError(_ error: LoopError, to dosingDecision: inout StoredDosingDecision) {
        dosingDecision.errors.append(issue(for: error))
    }

    fileprivate func appendErrors(_ errors: [LoopError], to dosingDecision: inout StoredDosingDecision) {
        for error in errors { appendError(error, to: &dosingDecision) }
    }

    fileprivate func appendWarning(_ warning: LoopAlgorithmWarning, to dosingDecision: inout StoredDosingDecision) {
        dosingDecision.warnings.append(issue(for: warning))
    }

    fileprivate func appendWarnings(_ warnings: [LoopAlgorithmWarning], to dosingDecision: inout StoredDosingDecision) {
        for warning in warnings { appendWarning(warning, to: &dosingDecision) }
    }

    /// Computes amount of insulin from boluses that have been issued and not confirmed, and
    /// remaining insulin delivery from temporary basal rate adjustments above scheduled rate
    /// that are still in progress.
    private func getPendingInsulin() throws -> Double {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let basalRates = basalRateScheduleApplyingOverrideHistory else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let pendingTempBasalInsulin: Double
        let date = now()

        if let basalDeliveryState = basalDeliveryState, case .tempBasal(let lastTempBasal) = basalDeliveryState, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.programmedUnits ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    public func predictGlucose(
        startingAt startingGlucoseOverride: GlucoseValue? = nil,
        using inputs: PredictionInputEffect,
        historicalInsulinEffect insulinEffectOverride: [GlucoseEffect]? = nil,
        insulinCounteractionEffects insulinCounteractionEffectsOverride: [GlucoseEffectVelocity]? = nil,
        historicalCarbEffect carbEffectOverride: [GlucoseEffect]? = nil,
        potentialBolus: DoseEntry? = nil,
        potentialCarbEntry: NewCarbEntry? = nil,
        replacingCarbEntry replacedCarbEntry: StoredCarbEntry? = nil,
        includingPendingInsulin: Bool = false,
        includingPositiveVelocityAndRC: Bool = true
    ) throws -> [PredictedGlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let glucose = startingGlucoseOverride ?? self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        let lastGlucoseDate = glucose.startDate

        guard now().timeIntervalSince(lastGlucoseDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard lastGlucoseDate.timeIntervalSince(now()) <= LoopCoreConstants.futureGlucoseDataInterval else {
            throw LoopError.invalidFutureGlucose(date: lastGlucoseDate)
        }

        guard now().timeIntervalSince(pumpStatusDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        var momentum: [GlucoseEffect] = []
        var retrospectiveGlucoseEffect = self.retrospectiveGlucoseEffect
        var effects: [[GlucoseEffect]] = []

        let insulinCounteractionEffects = insulinCounteractionEffectsOverride ?? self.insulinCounteractionEffects
        if inputs.contains(.carbs) {
            if let potentialCarbEntry = potentialCarbEntry {
                let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-type(of: retrospectiveCorrection).retrospectionInterval)

                if potentialCarbEntry.startDate > lastGlucoseDate || recentCarbEntries?.isEmpty != false, replacedCarbEntry == nil {
                    // The potential carb effect is independent and can be summed with the existing effect
                    if let carbEffect = carbEffectOverride ?? self.carbEffect {
                        effects.append(carbEffect)
                    }

                    let potentialCarbEffect = try carbStore.glucoseEffects(
                        of: [potentialCarbEntry],
                        startingAt: retrospectiveStart,
                        endingAt: nil,
                        effectVelocities: insulinCounteractionEffects
                    )

                    effects.append(potentialCarbEffect)
                } else {
                    var recentEntries = self.recentCarbEntries ?? []
                    if let replacedCarbEntry = replacedCarbEntry, let index = recentEntries.firstIndex(of: replacedCarbEntry) {
                        recentEntries.remove(at: index)
                    }

                    // If the entry is in the past or an entry is replaced, DCA and RC effects must be recomputed
                    var entries = recentEntries.map { NewCarbEntry(quantity: $0.quantity, startDate: $0.startDate, foodType: nil, absorptionTime: $0.absorptionTime) }
                    entries.append(potentialCarbEntry)
                    entries.sort(by: { $0.startDate > $1.startDate })

                    let potentialCarbEffect = try carbStore.glucoseEffects(
                        of: entries,
                        startingAt: retrospectiveStart,
                        endingAt: nil,
                        effectVelocities: insulinCounteractionEffects
                    )

                    effects.append(potentialCarbEffect)

                    retrospectiveGlucoseEffect = computeRetrospectiveGlucoseEffect(startingAt: glucose, carbEffects: potentialCarbEffect)
                }
            } else if let carbEffect = carbEffectOverride ?? self.carbEffect {
                effects.append(carbEffect)
            }
        }

        if inputs.contains(.insulin) {
            let computationInsulinEffect: [GlucoseEffect]?
            if insulinEffectOverride != nil {
                computationInsulinEffect = insulinEffectOverride
            } else {
                computationInsulinEffect = includingPendingInsulin ? self.insulinEffectIncludingPendingInsulin : self.insulinEffect
            }

            if let insulinEffect = computationInsulinEffect {
                effects.append(insulinEffect)
            }

            if let potentialBolus = potentialBolus {
                guard let sensitivity = insulinSensitivityScheduleApplyingOverrideHistory else {
                    throw LoopError.configurationError(.insulinSensitivitySchedule)
                }

                let earliestEffectDate = Date(timeInterval: .hours(-24), since: now())
                let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
                let bolusEffect = [potentialBolus]
                    .glucoseEffects(insulinModelProvider: doseStore.insulinModelProvider, longestEffectDuration: doseStore.longestEffectDuration, insulinSensitivity: sensitivity)
                    .filterDateRange(nextEffectDate, nil)
                effects.append(bolusEffect)
            }
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            if !includingPositiveVelocityAndRC, let netMomentum = momentumEffect.netEffect(), netMomentum.quantity.doubleValue(for: HKUnit(from: "mg/dL")) > 0 {
                momentum = []
            } else {
                momentum = momentumEffect
            }
        }

        if inputs.contains(.retrospection) {
            if !includingPositiveVelocityAndRC, let netRC = retrospectiveGlucoseEffect.netEffect(), netRC.quantity.doubleValue(for: HKUnit(from: "mg/dL")) > 0 {
                // positive RC is turned off
            } else {
                effects.append(retrospectiveGlucoseEffect)
            }
        }

        // Append effect of suspending insulin delivery when selected by the user on the Predicted Glucose screen (for information purposes only)
        if inputs.contains(.suspend) {
            effects.append(suspendInsulinDeliveryEffect)
        }

        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(doseStore.longestEffectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    public func predictGlucoseFromManualGlucose(
        _ glucose: NewGlucoseSample,
        potentialBolus: DoseEntry?,
        potentialCarbEntry: NewCarbEntry?,
        replacingCarbEntry replacedCarbEntry: StoredCarbEntry?,
        includingPendingInsulin: Bool,
        considerPositiveVelocityAndRC: Bool
    ) throws -> [PredictedGlucoseValue] {
        let retrospectiveStart = glucose.date.addingTimeInterval(-type(of: retrospectiveCorrection).retrospectionInterval)
        let earliestEffectDate = Date(timeInterval: .hours(-24), since: now())
        let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
        let insulinEffectStartDate = nextEffectDate.addingTimeInterval(.minutes(-5))

        let updateGroup = DispatchGroup()
        let effectCalculationError = Locked<Error?>(nil)

        var insulinEffect: [GlucoseEffect]?
        let basalDosingEnd = includingPendingInsulin ? nil : now()
        updateGroup.enter()
        doseStore.getGlucoseEffects(start: insulinEffectStartDate, end: nil, basalDosingEnd: basalDosingEnd) { result in
            switch result {
            case .failure(let error):
                effectCalculationError.mutate { $0 = error }
            case .success(let effects):
                insulinEffect = effects
            }

            updateGroup.leave()
        }

        updateGroup.wait()

        if let error = effectCalculationError.value {
            throw error
        }

        var insulinCounteractionEffects = self.insulinCounteractionEffects
        if nextEffectDate < glucose.date, let insulinEffect = insulinEffect {
            updateGroup.enter()
            glucoseStore.getGlucoseSamples(start: nextEffectDate, end: nil) { result in
                switch result {
                case .failure(let error):
                    self.logger.error("Failure getting glucose samples: \(String(describing: error))")
                case .success(let samples):
                    var samples = samples
                    let manualSample = StoredGlucoseSample(sample: glucose.quantitySample)
                    let insertionIndex = samples.loopAlgorithmCore_partitioningIndex(where: { manualSample.startDate < $0.startDate })
                    samples.insert(manualSample, at: insertionIndex)
                    let velocities = self.glucoseStore.counteractionEffects(for: samples, to: insulinEffect)
                    insulinCounteractionEffects.append(contentsOf: velocities)
                }
                insulinCounteractionEffects = insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)

                updateGroup.leave()
            }

            updateGroup.wait()
        }

        var carbEffect: [GlucoseEffect]?
        updateGroup.enter()
        carbStore.getGlucoseEffects(
            start: retrospectiveStart, end: nil,
            effectVelocities: insulinCounteractionEffects
        ) { result in
            switch result {
            case .failure(let error):
                effectCalculationError.mutate { $0 = error }
            case .success(let (_, effects)):
                carbEffect = effects
            }

            updateGroup.leave()
        }

        updateGroup.wait()

        if let error = effectCalculationError.value {
            throw error
        }

        return try predictGlucose(
            startingAt: glucose.quantitySample,
            using: [.insulin, .carbs],
            historicalInsulinEffect: insulinEffect,
            insulinCounteractionEffects: insulinCounteractionEffects,
            historicalCarbEffect: carbEffect,
            potentialBolus: potentialBolus,
            potentialCarbEntry: potentialCarbEntry,
            replacingCarbEntry: replacedCarbEntry,
            includingPendingInsulin: true,
            includingPositiveVelocityAndRC: considerPositiveVelocityAndRC
        )
    }

    public func recommendBolusForManualGlucose(_ glucose: NewGlucoseSample, consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation? {
        guard lastRequestedBolus == nil else {
            // Don't recommend changes if a bolus was just requested.
            return nil
        }

        let pendingInsulin = try getPendingInsulin()
        let shouldIncludePendingInsulin = pendingInsulin > 0
        let prediction = try predictGlucoseFromManualGlucose(glucose, potentialBolus: nil, potentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, includingPendingInsulin: shouldIncludePendingInsulin, considerPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        return try recommendManualBolus(forPrediction: prediction, consideringPotentialCarbEntry: potentialCarbEntry)
    }

    public func recommendBolus(consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?, replacingCarbEntry replacedCarbEntry: StoredCarbEntry?, considerPositiveVelocityAndRC: Bool) throws -> ManualBolusRecommendation? {
        guard lastRequestedBolus == nil else {
            return nil
        }

        let pendingInsulin = try getPendingInsulin()
        let shouldIncludePendingInsulin = pendingInsulin > 0
        let prediction = try predictGlucose(using: .all, potentialBolus: nil, potentialCarbEntry: potentialCarbEntry, replacingCarbEntry: replacedCarbEntry, includingPendingInsulin: shouldIncludePendingInsulin, includingPositiveVelocityAndRC: considerPositiveVelocityAndRC)
        return try recommendBolusValidatingDataRecency(forPrediction: prediction, consideringPotentialCarbEntry: potentialCarbEntry)
    }

    fileprivate func recommendBolusValidatingDataRecency<Sample: GlucoseValue>(forPrediction predictedGlucose: [Sample],
                                                                               consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?) throws -> ManualBolusRecommendation? {
        guard let glucose = glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }

        let pumpStatusDate = doseStore.lastAddedPumpData
        let lastGlucoseDate = glucose.startDate

        guard now().timeIntervalSince(lastGlucoseDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard lastGlucoseDate.timeIntervalSince(now()) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw LoopError.invalidFutureGlucose(date: lastGlucoseDate)
        }

        guard now().timeIntervalSince(pumpStatusDate) <= LoopCoreConstants.inputDataRecencyInterval else {
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil else {
            throw LoopError.missingDataError(.momentumEffect)
        }

        guard carbEffect != nil else {
            throw LoopError.missingDataError(.carbEffect)
        }

        guard insulinEffect != nil else {
            throw LoopError.missingDataError(.insulinEffect)
        }

        return try recommendManualBolus(forPrediction: predictedGlucose, consideringPotentialCarbEntry: potentialCarbEntry)
    }

    private func recommendManualBolus<Sample: GlucoseValue>(forPrediction predictedGlucose: [Sample],
                                                           consideringPotentialCarbEntry potentialCarbEntry: NewCarbEntry?) throws -> ManualBolusRecommendation? {
        guard let glucoseTargetRange = settings.effectiveGlucoseTargetRangeSchedule(presumingMealEntry: potentialCarbEntry != nil) else {
            throw LoopError.configurationError(.glucoseTargetRangeSchedule)
        }
        guard let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory else {
            throw LoopError.configurationError(.insulinSensitivitySchedule)
        }
        guard let maxBolus = settings.maximumBolus else {
            throw LoopError.configurationError(.maximumBolus)
        }

        guard lastRequestedBolus == nil
        else {
            return nil
        }

        let volumeRounder = { (_ units: Double) in
            return self.delegate?.loopAlgorithmRunner(self, roundBolusVolume: units) ?? units
        }

        let model = doseStore.insulinModelProvider.model(for: pumpInsulinType)

        return predictedGlucose.recommendedManualBolus(
            to: glucoseTargetRange,
            at: now(),
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            pendingInsulin: 0,
            maxBolus: maxBolus,
            volumeRounder: volumeRounder
        )
    }

    private func updateRetrospectiveGlucoseEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            throw LoopError.missingDataError(.carbEffect)
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            throw LoopError.missingDataError(.glucose)
        }

        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)

        let insulinSensitivity = settings.insulinSensitivitySchedule!.quantity(at: glucose.startDate)
        let basalRate = settings.basalRateSchedule!.value(at: glucose.startDate)
        let correctionRange = settings.glucoseTargetRangeSchedule!.quantityRange(at: glucose.startDate)

        retrospectiveGlucoseEffect = retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
            insulinSensitivity: insulinSensitivity,
            basalRate: basalRate,
            correctionRange: correctionRange,
            retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
        )
    }

    private func computeRetrospectiveGlucoseEffect(startingAt glucose: GlucoseValue, carbEffects: [GlucoseEffect]) -> [GlucoseEffect] {
        let insulinSensitivity = settings.insulinSensitivitySchedule!.quantity(at: glucose.startDate)
        let basalRate = settings.basalRateSchedule!.value(at: glucose.startDate)
        let correctionRange = settings.glucoseTargetRangeSchedule!.quantityRange(at: glucose.startDate)

        let retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)
        let retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * retrospectiveCorrectionGroupingIntervalMultiplier)
        return retrospectiveCorrection.computeEffect(
            startingAt: glucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: LoopCoreConstants.inputDataRecencyInterval,
            insulinSensitivity: insulinSensitivity,
            basalRate: basalRate,
            correctionRange: correctionRange,
            retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
        )
    }

    private func updateSuspendInsulinDeliveryEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory
        else {
            suspendInsulinDeliveryEffect = []
            throw LoopError.configurationError(.insulinSensitivitySchedule)
        }
        guard
            let basalRateSchedule = basalRateScheduleApplyingOverrideHistory
        else {
            suspendInsulinDeliveryEffect = []
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let insulinModel = doseStore.insulinModelProvider.model(for: pumpInsulinType)
        let insulinActionDuration = insulinModel.effectDuration

        let startSuspend = now()
        let endSuspend = startSuspend.addingTimeInterval(insulinActionDuration)

        var suspendDoses: [DoseEntry] = []
        let basalItems = basalRateSchedule.between(start: startSuspend, end: endSuspend)

        for (index, basalItem) in basalItems.enumerated() {
            var startSuspendDoseDate: Date
            var endSuspendDoseDate: Date

            if index == 0 {
                startSuspendDoseDate = startSuspend
            } else {
                startSuspendDoseDate = basalItem.startDate
            }

            if index == basalItems.count - 1 {
                endSuspendDoseDate = endSuspend
            } else {
                endSuspendDoseDate = basalItems[index + 1].startDate
            }

            let suspendDose = DoseEntry(type: .tempBasal, startDate: startSuspendDoseDate, endDate: endSuspendDoseDate, value: -basalItem.value, unit: DoseUnit.unitsPerHour)

            suspendDoses.append(suspendDose)
        }

        suspendInsulinDeliveryEffect = suspendDoses.glucoseEffects(insulinModelProvider: doseStore.insulinModelProvider, longestEffectDuration: doseStore.longestEffectDuration, insulinSensitivity: insulinSensitivity).filterDateRange(startSuspend, endSuspend)
    }

    private func updatePredictedGlucoseAndRecommendedDose(with dosingDecision: StoredDosingDecision) -> (StoredDosingDecision, LoopError?) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        var dosingDecision = dosingDecision

        self.logger.debug("Recomputing prediction and recommendations.")

        let startDate = now()

        guard let glucose = glucoseStore.latestGlucose else {
            logger.error("Latest glucose missing")
            appendError(LoopError.missingDataError(.glucose), to: &dosingDecision)
            return (dosingDecision, .missingDataError(.glucose))
        }

        var errors = [LoopError]()

        if startDate.timeIntervalSince(glucose.startDate) > LoopCoreConstants.inputDataRecencyInterval {
            errors.append(.glucoseTooOld(date: glucose.startDate))
        }

        if glucose.startDate.timeIntervalSince(startDate) > LoopCoreConstants.inputDataRecencyInterval {
            errors.append(.invalidFutureGlucose(date: glucose.startDate))
        }

        let pumpStatusDate = doseStore.lastAddedPumpData

        if startDate.timeIntervalSince(pumpStatusDate) > LoopCoreConstants.inputDataRecencyInterval {
            errors.append(.pumpDataTooOld(date: pumpStatusDate))
        }

        let glucoseTargetRange = settings.effectiveGlucoseTargetRangeSchedule()
        if glucoseTargetRange == nil {
            errors.append(.configurationError(.glucoseTargetRangeSchedule))
        }

        let basalRateSchedule = basalRateScheduleApplyingOverrideHistory
        if basalRateSchedule == nil {
            errors.append(.configurationError(.basalRateSchedule))
        }

        let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory
        if insulinSensitivity == nil {
            errors.append(.configurationError(.insulinSensitivitySchedule))
        }

        if carbRatioScheduleApplyingOverrideHistory == nil {
            errors.append(.configurationError(.carbRatioSchedule))
        }

        let maxBasal = settings.maximumBasalRatePerHour
        if maxBasal == nil {
            errors.append(.configurationError(.maximumBasalRatePerHour))
        }

        let maxBolus = settings.maximumBolus
        if maxBolus == nil {
            errors.append(.configurationError(.maximumBolus))
        }

        if glucoseMomentumEffect == nil {
            errors.append(.missingDataError(.momentumEffect))
        }

        if carbEffect == nil {
            errors.append(.missingDataError(.carbEffect))
        }

        if insulinEffect == nil {
            errors.append(.missingDataError(.insulinEffect))
        }

        if insulinEffectIncludingPendingInsulin == nil {
            errors.append(.missingDataError(.insulinEffectIncludingPendingInsulin))
        }

        if self.insulinOnBoard == nil {
            errors.append(.missingDataError(.activeInsulin))
        }

        appendErrors(errors, to: &dosingDecision)
        if let error = errors.first {
            logger.error("\(String(describing: error))")
            return (dosingDecision, error)
        }

        var loopError: LoopError?
        do {
            let predictedGlucose = try predictGlucose(using: settings.loopAlgorithmCore_enabledEffects)
            self.predictedGlucose = predictedGlucose
            let predictedGlucoseIncludingPendingInsulin = try predictGlucose(using: settings.loopAlgorithmCore_enabledEffects, includingPendingInsulin: true)
            self.predictedGlucoseIncludingPendingInsulin = predictedGlucoseIncludingPendingInsulin

            dosingDecision.predictedGlucose = predictedGlucose

            guard lastRequestedBolus == nil
            else {
                self.logger.debug("Not generating recommendations because bolus request is in progress.")
                return (dosingDecision, nil)
            }

            let rateRounder = { (_ rate: Double) in
                return self.delegate?.loopAlgorithmRunner(self, roundBasalRate: rate) ?? rate
            }

            let lastTempBasal: DoseEntry?

            if case .some(.tempBasal(let dose)) = basalDeliveryState {
                lastTempBasal = dose
            } else {
                lastTempBasal = nil
            }

            let dosingRecommendation: AutomaticDoseRecommendation?

            // automaticDosingIOBLimit calculated from the user entered maxBolus
            let automaticDosingIOBLimit = maxBolus! * 2.0
            let iobHeadroom = automaticDosingIOBLimit - self.insulinOnBoard!.value

            switch settings.automaticDosingStrategy {
            case .automaticBolus:
                let volumeRounder = { (_ units: Double) in
                    return self.delegate?.loopAlgorithmRunner(self, roundBolusVolume: units) ?? units
                }

                // Create dosing strategy based on user setting
                let applicationFactorStrategy: ApplicationFactorStrategy = featureFlagProvider.glucoseBasedApplicationFactorEnabled
                    ? GlucoseBasedApplicationFactorStrategy()
                    : ConstantApplicationFactorStrategy()

                let correctionRangeSchedule = settings.effectiveGlucoseTargetRangeSchedule()

                let effectiveBolusApplicationFactor = applicationFactorStrategy.calculateDosingFactor(
                    for: glucose.quantity,
                    correctionRangeSchedule: correctionRangeSchedule!,
                    settings: settings
                )

                self.logger.debug(" *** Glucose: \(glucose.quantity.description), effectiveBolusApplicationFactor: \(effectiveBolusApplicationFactor)")

                // If a user customizes maxPartialApplicationFactor > 1; this respects maxBolus
                let maxAutomaticBolus = min(iobHeadroom, maxBolus! * min(effectiveBolusApplicationFactor, 1.0))

                dosingRecommendation = predictedGlucose.recommendedAutomaticDose(
                    to: glucoseTargetRange!,
                    at: predictedGlucose[0].startDate,
                    suspendThreshold: settings.suspendThreshold?.quantity,
                    sensitivity: insulinSensitivity!,
                    model: doseStore.insulinModelProvider.model(for: pumpInsulinType),
                    basalRates: basalRateSchedule!,
                    maxAutomaticBolus: maxAutomaticBolus,
                    partialApplicationFactor: effectiveBolusApplicationFactor * self.timeBasedDoseApplicationFactor,
                    lastTempBasal: lastTempBasal,
                    volumeRounder: volumeRounder,
                    rateRounder: rateRounder,
                    isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
                )
            case .tempBasalOnly:
                let temp = predictedGlucose.recommendedTempBasal(
                    to: glucoseTargetRange!,
                    at: predictedGlucose[0].startDate,
                    suspendThreshold: settings.suspendThreshold?.quantity,
                    sensitivity: insulinSensitivity!,
                    model: doseStore.insulinModelProvider.model(for: pumpInsulinType),
                    basalRates: basalRateSchedule!,
                    maxBasalRate: maxBasal!,
                    additionalActiveInsulinClamp: iobHeadroom,
                    lastTempBasal: lastTempBasal,
                    rateRounder: rateRounder,
                    isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
                )
                dosingRecommendation = AutomaticDoseRecommendation(basalAdjustment: temp)
            }

            if let dosingRecommendation = dosingRecommendation {
                self.logger.default("Recommending dose: \(String(describing: dosingRecommendation)) at \(String(describing: startDate))")
                recommendedAutomaticDose = (recommendation: dosingRecommendation, date: startDate)
            } else {
                self.logger.default("No dose recommended.")
                recommendedAutomaticDose = nil
            }
            dosingDecision.automaticDoseRecommendation = recommendedAutomaticDose?.recommendation
        } catch let error {
            loopError = error as? LoopError ?? .unknownError(error)
            if let loopError = loopError {
                logger.error("Error attempting to predict glucose: \(String(describing: loopError))")
                appendError(loopError, to: &dosingDecision)
            }
        }

        return (dosingDecision, loopError)
    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func enactRecommendedAutomaticDose() -> LoopError? {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedDose = self.recommendedAutomaticDose else {
            return nil
        }

        guard abs(recommendedDose.date.timeIntervalSince(now())) < TimeInterval(minutes: 5) else {
            return LoopError.recommendationExpired(date: recommendedDose.date)
        }

        if case .suspended = basalDeliveryState {
            return LoopError.pumpSuspended
        }

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var delegateError: LoopError?

        if let delegate = delegate {
            delegate.loopAlgorithmRunner(self, didRecommend: recommendedDose) { (error) in
                delegateError = error
                updateGroup.leave()
            }
        } else {
            // No delegate wired (test/standalone). Treat as no-op success so the algorithm proceeds.
            updateGroup.leave()
        }
        updateGroup.wait()

        if delegateError == nil {
            self.recommendedAutomaticDose = nil
        }

        return delegateError
    }

    /// Ensures that the current temp basal is at or below the proposed max temp basal, and if not, cancel it before proceeding.
    public func maxTempBasalSavePreflight(unitsPerHour: Double?, completion: @escaping (_ error: Error?) -> Void) {
        guard let unitsPerHour = unitsPerHour else {
            completion(nil)
            return
        }
        dataAccessQueue.async {
            switch self.basalDeliveryState {
            case .some(.tempBasal(let dose)):
                if dose.unitsPerHour > unitsPerHour {
                    self.cancelActiveTempBasal(for: .maximumBasalRateChanged, completion: completion)
                } else {
                    completion(nil)
                }
            default:
                completion(nil)
            }
        }
    }

    // MARK: - High-level overrides / carb actions

    public func enactOverride(_ override: TemporaryScheduleOverride?) async {
        mutateSettings { settings in settings.scheduleOverride = override }
    }
}

// MARK: - AutomaticDosingStatus bridge

/// A cross-platform abstraction for the iOS-only `AutomaticDosingStatus` class.
/// iOS's `AutomaticDosingStatus` already exposes `automaticDosingEnabled` and
/// `isAutomaticDosingAllowed` Combine `@Published` properties; the watch will
/// expose its own publisher backed by synced settings. This protocol keeps the
/// runner unaware of the concrete class.
public protocol AutomaticDosingStatusBridge: AnyObject {
    var automaticDosingEnabled: Bool { get }
    var isAutomaticDosingAllowed: Bool { get }
}

// MARK: - OSLog shim

/// Lightweight wrapper around `os.Logger` so the runner has a logger without
/// pulling in LoopKit's `DiagnosticLog` (which is iOS-target specific).
final class OSLogShim {
    private let logger: os.Logger
    init(category: String) {
        self.logger = os.Logger(subsystem: "com.loopkit.LoopAlgorithmCore", category: category)
    }
    func `default`(_ message: String) { logger.log("\(message, privacy: .public)") }
    func debug(_ message: String)     { logger.debug("\(message, privacy: .public)") }
    func error(_ message: String)     { logger.error("\(message, privacy: .public)") }
}

// MARK: - Private helpers (mirrored from LoopDataManager.swift)

private extension TemporaryScheduleOverride {
    func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date), let basalRateMultiplier = settings.basalRateMultiplier else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
}

private extension StoredDosingDecision.LastReservoirValue {
    init?(_ reservoirValue: ReservoirValue?) {
        guard let reservoirValue = reservoirValue else {
            return nil
        }
        self.init(startDate: reservoirValue.startDate, unitVolume: reservoirValue.unitVolume)
    }
}

private extension StoredDosingDecision.Settings {
    init?(_ settings: StoredSettings?) {
        guard let settings = settings else {
            return nil
        }
        self.init(syncIdentifier: settings.syncIdentifier)
    }
}
