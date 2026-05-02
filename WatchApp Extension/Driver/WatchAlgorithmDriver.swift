//
//  WatchAlgorithmDriver.swift
//  WatchApp Extension
//
//  Watch-side mirror of iOS LoopDataManager. Constructs a `LoopAlgorithmRunner`
//  with watch-side stores; conforms to `LoopAlgorithmRunnerDelegate` plus the
//  three provider protocols (controller status, latest stored settings,
//  feature flags); routes algorithm callbacks to watch-specific orchestration
//  (WKExtendedRuntimeSession refresh hint, complication reload).
//
//  Constructed by `WatchAlgorithmBootstrap` when the handoff state machine
//  reaches `.watchDriver`. Torn down when the state leaves `.watchDriver`.
//
//  Architectural notes:
//  - The watch does not (yet) own iOS's full set of stores. Phase 5 mocks
//    those collaborators that don't exist on watch (`DosingDecisionStore`
//    is constructed against an in-memory `PersistenceController`).
//  - `AnalyticsServicesManager`, `LiveActivityManager`, `WidgetCenter`,
//    `MealDetectionManager`, and the iOS preset-activation observers are
//    all skipped — they're iOS-only, and the runner's default no-op
//    delegate implementations cover the gap.
//  - Settings come from a `WatchSettingsSnapshot` placeholder. Phase 6 will
//    replace this with `PhoneWatchSettingsSync` (real WCSession pull).
//
//  B.3.a Phase 5. Phase 7: isWarmingUp tracking.
//

#if !os(iOS)

import Combine
import Foundation
import HealthKit
import LoopAlgorithmCore
import LoopKit
import LoopCore
import OmniBLE  // for PhoneWatchSettingsSync (Phase 6)
import os.log
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(ClockKit)
import ClockKit
#endif

// MARK: - Settings snapshot

/// A read-only snapshot of the most recent settings the watch has received
/// from the phone. Used by `WatchAlgorithmDriver` adapters and by the
/// Phase 5 bootstraps. Phase 6 populates via `PhoneWatchSettingsSync` (see
/// `init(fromSync:)` below); Phase 5 tests still construct it directly.
final class WatchSettingsSnapshot {

    /// The most recent `LoopSettings` synced from the phone.
    let loopSettings: LoopSettings

    /// The most recent `StoredSettings` snapshot synced from the phone.
    let storedSettings: StoredSettings

    /// Nightscout configuration (URL + API secret) if the phone has
    /// configured one. `nil` means "do not start RemoteDataServicesManager
    /// against Nightscout."
    let nightscoutConfig: NightscoutConfig?

    /// Whether the phone has automatic dosing turned on.
    let automaticDosingEnabled: Bool

    /// Whether automatic dosing is currently allowed (not blocked by, e.g.,
    /// a pump comms failure).
    let isAutomaticDosingAllowed: Bool

    init(loopSettings: LoopSettings = LoopSettings(),
         storedSettings: StoredSettings = StoredSettings(),
         nightscoutConfig: NightscoutConfig? = nil,
         automaticDosingEnabled: Bool = false,
         isAutomaticDosingAllowed: Bool = false) {
        self.loopSettings = loopSettings
        self.storedSettings = storedSettings
        self.nightscoutConfig = nightscoutConfig
        self.automaticDosingEnabled = automaticDosingEnabled
        self.isAutomaticDosingAllowed = isAutomaticDosingAllowed
    }

    /// B.3.a Phase 6: construct from a real `PhoneWatchSettingsSync` received
    /// over WCSession. Converts the transport struct into the richer local
    /// type that `WatchAlgorithmDriver` adapters expect.
    init(fromSync sync: PhoneWatchSettingsSync) {
        let basalSchedule = sync.basalScheduleItems.isEmpty ? nil
            : BasalRateSchedule(dailyItems: sync.basalScheduleItems, timeZone: TimeZone.current)
        let isfSchedule = sync.insulinSensitivityScheduleItems.isEmpty ? nil
            : InsulinSensitivitySchedule(unit: .milligramsPerDeciliter,
                                         dailyItems: sync.insulinSensitivityScheduleItems,
                                         timeZone: TimeZone.current)
        let carbSchedule = sync.carbRatioScheduleItems.isEmpty ? nil
            : CarbRatioSchedule(unit: .gram(),
                                dailyItems: sync.carbRatioScheduleItems,
                                timeZone: TimeZone.current)
        let targetSchedule = sync.glucoseTargetRangeScheduleItems.isEmpty ? nil
            : GlucoseRangeSchedule(unit: .milligramsPerDeciliter,
                                   dailyItems: sync.glucoseTargetRangeScheduleItems,
                                   timeZone: TimeZone.current)
        let suspendThreshold: GlucoseThreshold? = sync.suspendThresholdMgdL.map {
            GlucoseThreshold(unit: .milligramsPerDeciliter, value: $0)
        }

        var ls = LoopSettings()
        ls.basalRateSchedule = basalSchedule
        ls.insulinSensitivitySchedule = isfSchedule
        ls.carbRatioSchedule = carbSchedule
        ls.glucoseTargetRangeSchedule = targetSchedule
        ls.maximumBolus = sync.maximumBolusUnits
        ls.maximumBasalRatePerHour = sync.maximumBasalRatePerHourUnits
        ls.suspendThreshold = suspendThreshold
        self.loopSettings = ls

        self.storedSettings = StoredSettings(
            glucoseTargetRangeSchedule: targetSchedule,
            maximumBasalRatePerHour: sync.maximumBasalRatePerHourUnits,
            maximumBolus: sync.maximumBolusUnits,
            suspendThreshold: suspendThreshold,
            basalRateSchedule: basalSchedule,
            insulinSensitivitySchedule: isfSchedule,
            carbRatioSchedule: carbSchedule
        )

        if let ns = sync.nightscoutConfig {
            self.nightscoutConfig = NightscoutConfig(siteURL: ns.url, apiSecret: ns.apiSecret)
        } else {
            self.nightscoutConfig = nil
        }

        // B.4 Issue #3: read from sync; default to false (fail-closed) when
        // the v1 sender didn't include them, when the new fields are explicitly
        // nil, or when the phone reports automatic dosing is off / disallowed.
        self.automaticDosingEnabled = sync.automaticDosingEnabled ?? false
        self.isAutomaticDosingAllowed = sync.isAutomaticDosingAllowed ?? false
    }

    struct NightscoutConfig {
        let siteURL: URL
        let apiSecret: String
    }
}

// MARK: - Suppression reasons (B.6)

/// Why a watch-side automatic dose was suppressed instead of enacted.
/// Persisted into `StoredDosingDecision.reason` so the iOS event log
/// shows why the watch decided not to dose. Reason strings are namespaced
/// with `watchSuppressed.` to disambiguate from iOS's bare-string reasons
/// like `"loop"` / `"getLoopState"` (per Phase 1 discovery).
enum WatchDoseSuppressionReason: String {
    /// The watch is still in its warming-up window (first ~30 min after handoff).
    case warmingUp = "watchSuppressed.warmingUp"
    /// The phone reported automatic dosing is turned off.
    case automaticDosingDisabled = "watchSuppressed.automaticDosingDisabled"
    /// The phone reported automatic dosing is currently not allowed
    /// (e.g., pump comms failure).
    case automaticDosingNotAllowed = "watchSuppressed.automaticDosingNotAllowed"
    /// No pump manager is available (driver was constructed without one).
    case noPumpManager = "watchSuppressed.noPumpManager"
}

// MARK: - Driver

final class WatchAlgorithmDriver: NSObject, ObservableObject {

    // MARK: Stored collaborators

    private let runner: LoopAlgorithmRunner
    private let settingsSnapshot: WatchSettingsSnapshot
    private let log = OSLog(subsystem: "com.loopkit.Loop.WatchApp", category: "WatchAlgorithmDriver")

    /// B.6: Pump manager for dose enactment. Nil during construction or when
    /// the watch hasn't yet been wired to an OmniBLEPumpManager — the
    /// didRecommend override treats nil as "suppress all doses."
    private let pumpManager: PumpManager?

    /// B.6: Persistent reference for recording suppressed dose decisions.
    /// The runner already gets the same store; we keep our own handle so the
    /// didRecommend override can write suppression records without going
    /// through the runner.
    private let dosingDecisionStore: DosingDecisionStoreProtocol

    /// B.6: Test-only override — when set, replaces the published value of
    /// isWarmingUp at init time. Production callers leave this nil.
    private let isWarmingUpOverride: Bool?

    // MARK: Warm-up tracking (B.3.a Phase 7)

    /// True from construction until the runner completes its first full loop
    /// iteration after handoff. During this window the algorithm's CoreData
    /// stores are still backfilling from the G7 sensor and pod history, so
    /// predictions are limited.
    @Published private(set) var isWarmingUp: Bool = true
    private var didCompleteFirstIteration = false

    // MARK: Construction

    /// Builds a `LoopAlgorithmRunner` against the supplied watch-side stores.
    /// The driver retains the runner and serves as its delegate plus all
    /// three provider protocols.
    init(carbStore: CarbStoreProtocol,
         doseStore: DoseStoreProtocol,
         glucoseStore: GlucoseStoreProtocol,
         dosingDecisionStore: DosingDecisionStoreProtocol,
         settingsSnapshot: WatchSettingsSnapshot,
         pumpInsulinType: InsulinType? = nil,
         now: @escaping () -> Date = { Date() },
         trustedTimeOffset: @escaping () -> TimeInterval = { 0 },
         pumpManager: PumpManager? = nil,                    // B.6: dose-emission target (nil → suppress all)
         isWarmingUpOverride: Bool? = nil) {                 // B.6: test-only override
        self.settingsSnapshot = settingsSnapshot
        self.pumpManager = pumpManager
        self.dosingDecisionStore = dosingDecisionStore
        self.isWarmingUpOverride = isWarmingUpOverride

        // Provider conformances live on `self`, but `self` isn't fully
        // initialized yet. Construct lightweight adapter shims that hold weak
        // references back to the driver, then resolve them at first call.
        let controllerStatusAdapter = WatchControllerStatusAdapter()
        let featureFlagAdapter = WatchFeatureFlagAdapter(snapshot: settingsSnapshot)
        let latestStoredSettingsAdapter = WatchLatestStoredSettingsAdapter(snapshot: settingsSnapshot)
        let dosingStatusAdapter = WatchAutomaticDosingStatusAdapter(snapshot: settingsSnapshot)

        self.runner = LoopAlgorithmRunner(
            lastLoopCompleted: nil,
            basalDeliveryState: nil,
            settings: settingsSnapshot.loopSettings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: latestStoredSettingsAdapter,
            controllerStatusProvider: controllerStatusAdapter,
            featureFlagProvider: featureFlagAdapter,
            automaticDosingStatus: dosingStatusAdapter,
            pumpInsulinType: pumpInsulinType,
            trustedTimeOffset: trustedTimeOffset,
            now: now
        )

        super.init()

        // weak delegate; runner owns its half of the cycle.
        self.runner.delegate = self

        // B.6: apply test override if supplied. Setting didCompleteFirstIteration
        // alongside ensures the next loop tick doesn't re-trigger the warmup-
        // cleared notification path (per Phase 1 discovery).
        if let override = isWarmingUpOverride {
            self.isWarmingUp = override
            if !override {
                self.didCompleteFirstIteration = true
            }
        }
    }

    // MARK: Test / introspection helpers

    /// Test-only access to the underlying runner. Phase-5 tests assert on
    /// "construction succeeded" rather than driving the algorithm; this
    /// accessor is intentionally minimal.
    var underlyingRunner: LoopAlgorithmRunner { runner }
}

// MARK: - Notification names (B.3.a Phase 7)

extension WatchAlgorithmDriver {
    /// Posted on the main queue when `isWarmingUp` transitions from `true` to
    /// `false` (i.e., the runner has completed its first full iteration after
    /// handoff). `object` is the `WatchAlgorithmDriver` instance.
    static let warmUpDidCompleteNotification = Notification.Name(
        "com.loopkit.Loop.WatchAlgorithmDriver.warmUpDidComplete"
    )
}

// MARK: - LoopAlgorithmRunnerDelegate (watch orchestration)

extension WatchAlgorithmDriver: LoopAlgorithmRunnerDelegate {

    func loopAlgorithmRunnerDidStartLoop(_ runner: LoopAlgorithmRunner) {
        log.default("WatchAlgorithmDriver: loop iteration starting")
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidComplete date: Date,
                             duration: TimeInterval) {
        log.default("WatchAlgorithmDriver: loop completed in %{public}.2fs", duration)
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidError error: LoopError,
                             duration: TimeInterval) {
        log.error("WatchAlgorithmDriver: loop errored after %{public}.2fs: %{public}@",
                  duration, String(describing: error))
    }

    func loopAlgorithmRunnerDidFinishLoop(_ runner: LoopAlgorithmRunner) {
        log.default("WatchAlgorithmDriver: loop finished — refreshing complications")
        // B.3.a Phase 7: clear warm-up flag on first completed iteration and
        // notify WatchKit controllers (which cannot use Combine/ObservableObject
        // directly) via NotificationCenter.
        if !didCompleteFirstIteration {
            didCompleteFirstIteration = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isWarmingUp = false
                NotificationCenter.default.post(
                    name: WatchAlgorithmDriver.warmUpDidCompleteNotification,
                    object: self
                )
            }
        }
        refreshComplications()
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didChange context: LoopAlgorithmUpdateContext) {
        // Watch UI listens via its own publishers; no NotificationCenter
        // bridging is needed here. Logged for diagnostics.
        log.debug("WatchAlgorithmDriver: state changed (context=%{public}@)",
                  String(describing: context))
    }

    // B.6: dose-emission with gating. Phase 5 left this as the default
    // no-op (algorithm decided, recommendation discarded). Now: check
    // 4 gates (warming-up, automaticDosingEnabled, isAutomaticDosingAllowed,
    // pumpManager non-nil), record suppressed decisions to the
    // dosingDecisionStore so they appear in event history, otherwise
    // dispatch the dose to the pump manager.
    //
    // CRITICAL: completion(nil) is load-bearing on the suppression path.
    // LoopAlgorithmRunner only clears its cached recommendedAutomaticDose
    // when the delegate completion is called with nil; calling with an
    // error (or skipping completion) would cause the algorithm to retry
    // the same recommendation on the next tick. (Phase 1 discovery.)
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
                             completion: @escaping (LoopError?) -> Void) {
        // Gate 1: warming-up window. Order matters — only the first failing
        // gate's reason is recorded.
        if isWarmingUp {
            recordSuppressed(automaticDose, reason: .warmingUp)
            completion(nil)
            return
        }
        // Gate 2: phone reports automatic dosing is off.
        if !settingsSnapshot.automaticDosingEnabled {
            recordSuppressed(automaticDose, reason: .automaticDosingDisabled)
            completion(nil)
            return
        }
        // Gate 3: phone reports automatic dosing is currently disallowed.
        if !settingsSnapshot.isAutomaticDosingAllowed {
            recordSuppressed(automaticDose, reason: .automaticDosingNotAllowed)
            completion(nil)
            return
        }
        // Gate 4: no pump manager available (defensive).
        guard let pumpManager = pumpManager else {
            recordSuppressed(automaticDose, reason: .noPumpManager)
            completion(nil)
            return
        }

        log.default("WatchAlgorithmDriver: enacting recommended dose: %{public}@",
                    String(describing: automaticDose.recommendation))
        enactRecommendedDose(automaticDose.recommendation, with: pumpManager, completion: completion)
    }

    // The runner's default `settingsDidChange`, rounding, and missed-meal hooks
    // all default to no-op / pass-through, which is the right behavior on watch
    // for Phase 5/6 scope. Future phases may refine.

    // Issue conversion: defaults stringify, which is fine for watch.

    // MARK: - B.6 dose enactment + suppression recording

    /// Records a suppressed automatic dose into the dosingDecisionStore so it
    /// appears in the watch's (and via sync, the phone's) event history.
    /// The recommendation is preserved so the user can see what would have
    /// been dosed if the gates had passed.
    private func recordSuppressed(_ automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
                                   reason: WatchDoseSuppressionReason) {
        log.default("WatchAlgorithmDriver: suppressed dose (%{public}@): %{public}@",
                    reason.rawValue,
                    String(describing: automaticDose.recommendation))
        let decision = makeSuppressedDecision(automaticDose: automaticDose, reason: reason)
        dosingDecisionStore.storeDosingDecision(decision) { /* fire-and-forget */ }
    }

    /// Constructs a `StoredDosingDecision` describing the suppressed dose.
    /// Uses the iOS pattern (mirrors LoopAlgorithmRunner.swift:945): init with
    /// the required `reason: String` field, then assign other fields var-style.
    /// All StoredDosingDecision fields are `public var` so post-init assignment
    /// is the canonical pattern (per Phase 1 discovery).
    private func makeSuppressedDecision(
        automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
        reason: WatchDoseSuppressionReason
    ) -> StoredDosingDecision {
        var decision = StoredDosingDecision(
            date: automaticDose.date,
            reason: reason.rawValue
        )
        decision.automaticDoseRecommendation = automaticDose.recommendation
        return decision
    }

    /// Mirrors iOS `DoseEnactor.enact(...)` inline (DoseEnactor lives in iOS
    /// Loop target only; not shared). Temp basal first, then bolus, both via
    /// DispatchGroup. Result is a single LoopError? — the first failure
    /// short-circuits.
    private func enactRecommendedDose(
        _ recommendation: AutomaticDoseRecommendation,
        with pumpManager: PumpManager,
        completion: @escaping (LoopError?) -> Void
    ) {
        let queue = DispatchQueue(label: "com.loopkit.WatchAlgorithmDriver.dosingQueue", qos: .utility)
        queue.async {
            let group = DispatchGroup()
            var tempBasalError: PumpManagerError?
            var bolusError: PumpManagerError?

            if let basalAdjustment = recommendation.basalAdjustment {
                group.enter()
                pumpManager.enactTempBasal(
                    unitsPerHour: basalAdjustment.unitsPerHour,
                    for: basalAdjustment.duration
                ) { error in
                    tempBasalError = error
                    group.leave()
                }
            }
            group.wait()

            guard tempBasalError == nil else {
                completion(tempBasalError.map { .pumpManagerError($0) })
                return
            }

            if let bolusUnits = recommendation.bolusUnits, bolusUnits > 0 {
                group.enter()
                pumpManager.enactBolus(units: bolusUnits, activationType: .automatic) { error in
                    bolusError = error
                    group.leave()
                }
            }
            group.wait()
            completion(bolusError.map { .pumpManagerError($0) })
        }
    }

    // MARK: Watch-specific helpers

    private func refreshComplications() {
        #if canImport(ClockKit)
        let server = CLKComplicationServer.sharedInstance()
        for complication in server.activeComplications ?? [] {
            server.reloadTimeline(for: complication)
        }
        #endif
    }
}

// MARK: - Provider adapters
//
// Each adapter is a small final class that conforms to one of the three
// LoopAlgorithmCore provider protocols. Holding adapters separately from the
// driver itself sidesteps "self before super.init" + protocol-conformance
// ordering issues, and keeps each surface narrowly scoped.

/// Provides controller status (battery / charging) folded into every
/// `StoredDosingDecision`. Watch reads from `WKInterfaceDevice` when
/// available; falls back to nil if unreachable.
private final class WatchControllerStatusAdapter: LoopAlgorithmControllerStatusProvider {
    var controllerStatus: StoredDosingDecision.ControllerStatus? {
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        let batteryLevel: Float = device.batteryLevel
        return StoredDosingDecision.ControllerStatus(
            batteryState: Self.mapBatteryState(device.batteryState),
            batteryLevel: batteryLevel.isFinite && batteryLevel >= 0 ? batteryLevel : nil
        )
        #else
        return nil
        #endif
    }

    #if canImport(WatchKit)
    private static func mapBatteryState(_ state: WKInterfaceDeviceBatteryState)
        -> StoredDosingDecision.ControllerStatus.BatteryState? {
        switch state {
        case .charging:  return .charging
        case .full:      return .full
        case .unplugged: return .unplugged
        case .unknown:   return .unknown
        @unknown default: return .unknown
        }
    }
    #endif
}

/// Wraps a `WatchSettingsSnapshot` to satisfy
/// `LoopAlgorithmLatestStoredSettingsProvider`.
private final class WatchLatestStoredSettingsAdapter: LoopAlgorithmLatestStoredSettingsProvider {
    let snapshot: WatchSettingsSnapshot
    init(snapshot: WatchSettingsSnapshot) { self.snapshot = snapshot }
    var latestSettings: StoredSettings { snapshot.storedSettings }
}

/// Watch feature-flag provider. The watch never enables iOS-only UI
/// toggles (integral retro correction, glucose-based application factor),
/// and the missed-meal notification path is iOS-only too. Default: all off.
private final class WatchFeatureFlagAdapter: LoopAlgorithmFeatureFlagProvider {
    let snapshot: WatchSettingsSnapshot
    init(snapshot: WatchSettingsSnapshot) { self.snapshot = snapshot }

    var integralRetrospectiveCorrectionEnabled: Bool { false }
    var glucoseBasedApplicationFactorEnabled: Bool { false }
    var missedMealNotificationsEnabled: Bool { false }
}

/// Watch-side `AutomaticDosingStatusBridge`. Pulls from the synced settings
/// snapshot.
private final class WatchAutomaticDosingStatusAdapter: AutomaticDosingStatusBridge {
    let snapshot: WatchSettingsSnapshot
    init(snapshot: WatchSettingsSnapshot) { self.snapshot = snapshot }
    var automaticDosingEnabled: Bool { snapshot.automaticDosingEnabled }
    var isAutomaticDosingAllowed: Bool { snapshot.isAutomaticDosingAllowed }
}

#endif  // !os(iOS)
