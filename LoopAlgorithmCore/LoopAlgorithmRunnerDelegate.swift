//
//  LoopAlgorithmRunnerDelegate.swift
//  LoopAlgorithmCore
//
//  Side-effect protocol that LoopAlgorithmRunner uses to push lifecycle
//  events, recommended doses, and configuration-change notifications out to
//  the host orchestrator.
//
//  iOS LoopDataManager and (future) WatchAlgorithmDriver each conform; iOS
//  bridges to NSNotificationCenter / LiveActivity / Widgets, watch bridges
//  to its reactive state stream and complications.
//
//  Phase 2.D: protocol shipped; no caller wired up yet.
//
//  Part of B.3.a — see:
//    docs/superpowers/specs/2026-04-26-b3a-watch-self-driving-design.md
//    docs/research/2026-04-26-loopalgorithmcore-extraction.md
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

// MARK: - Update context

/// Categorizes the source of a loop-state change for downstream listeners.
///
/// Mirrors the iOS-only `LoopDataManager.LoopUpdateContext` so the runner can
/// describe what triggered an update without depending on the iOS app target.
public enum LoopAlgorithmUpdateContext: Int {
    case insulin
    case carbs
    case glucose
    case preferences
    case loopFinished
}

// MARK: - Settings-change impact bundle

/// Snapshot describing what changed during a `mutateSettings` call.
///
/// The runner produces this synchronously inside `mutateSettings`; the host
/// delegate fans the impact out to LiveActivity / analytics / preset observers
/// without needing to re-diff the settings itself.
public struct LoopAlgorithmSettingsChangeImpact {
    public let oldSettings: LoopSettings
    public let newSettings: LoopSettings
    public let preMealOverrideChanged: Bool
    public let scheduleOverrideChanged: Bool
    public let insulinSensitivityScheduleChanged: Bool
    public let basalRateScheduleChanged: Bool
    public let carbRatioScheduleChanged: Bool
    public let insulinModelChanged: Bool
    public let maximumBolusChanged: Bool

    public init(
        oldSettings: LoopSettings,
        newSettings: LoopSettings,
        preMealOverrideChanged: Bool,
        scheduleOverrideChanged: Bool,
        insulinSensitivityScheduleChanged: Bool,
        basalRateScheduleChanged: Bool,
        carbRatioScheduleChanged: Bool,
        insulinModelChanged: Bool,
        maximumBolusChanged: Bool
    ) {
        self.oldSettings = oldSettings
        self.newSettings = newSettings
        self.preMealOverrideChanged = preMealOverrideChanged
        self.scheduleOverrideChanged = scheduleOverrideChanged
        self.insulinSensitivityScheduleChanged = insulinSensitivityScheduleChanged
        self.basalRateScheduleChanged = basalRateScheduleChanged
        self.carbRatioScheduleChanged = carbRatioScheduleChanged
        self.insulinModelChanged = insulinModelChanged
        self.maximumBolusChanged = maximumBolusChanged
    }
}

// MARK: - Provider protocols

/// Provides the controller (host device) status that the runner folds into
/// `StoredDosingDecision.controllerStatus`. iOS implements via `UIDevice`,
/// watch via `WKInterfaceDevice` / `ProcessInfo`.
public protocol LoopAlgorithmControllerStatusProvider: AnyObject {
    var controllerStatus: StoredDosingDecision.ControllerStatus? { get }
}

/// Provides the most recently persisted settings snapshot, used to tag dosing
/// decisions. iOS impl reads `SettingsManager`; watch impl reads the synced
/// `PhoneWatchSettingsSyncCache`.
public protocol LoopAlgorithmLatestStoredSettingsProvider: AnyObject {
    var latestSettings: StoredSettings { get }
}

/// Provides algorithm feature flags. iOS impl reads `UserDefaults.standard`;
/// watch impl reads from synced settings (since toggles are iOS-only).
public protocol LoopAlgorithmFeatureFlagProvider: AnyObject {
    var integralRetrospectiveCorrectionEnabled: Bool { get }
    var glucoseBasedApplicationFactorEnabled: Bool { get }
    var missedMealNotificationsEnabled: Bool { get }
}

// MARK: - Runner delegate

/// Side-effect callbacks that `LoopAlgorithmRunner` invokes during its
/// algorithm lifecycle. All members have default no-op implementations so
/// callers may override only what they need.
///
/// `AnyObject` is required — the runner holds a `weak var delegate`.
public protocol LoopAlgorithmRunnerDelegate: AnyObject {

    // MARK: Lifecycle notifications

    /// Invoked from `loopInternal()` immediately before the algorithm starts.
    /// iOS bridges to `NotificationCenter.post(name: .LoopRunning)`.
    func loopAlgorithmRunnerDidStartLoop(_ runner: LoopAlgorithmRunner)

    /// Invoked when a loop iteration completes successfully.
    /// iOS bridges to analytics + `NotificationCenter.post(name: .LoopCompleted)`.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidComplete date: Date,
                             duration: TimeInterval)

    /// Invoked when a loop iteration ends in error.
    /// iOS bridges to analytics; the runner already appended the error to the
    /// dosing decision before invoking this.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidError error: LoopError,
                             duration: TimeInterval)

    /// Invoked at the end of `finishLoop`. iOS bridges to a delayed
    /// `WidgetCenter.shared.reloadAllTimelines()` call.
    func loopAlgorithmRunnerDidFinishLoop(_ runner: LoopAlgorithmRunner)

    /// Invoked whenever cached loop state changes. iOS bridges to
    /// `NotificationCenter.post(name: .LoopDataUpdated, userInfo: [...])`.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didChange context: LoopAlgorithmUpdateContext)

    // MARK: Settings change

    /// Invoked synchronously from `mutateSettings` after the runner finishes
    /// applying its own state mutations. Lets the host fan out to
    /// LiveActivity / analytics / preset observers.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             settingsDidChange impact: LoopAlgorithmSettingsChangeImpact)

    // MARK: Pump enactment + rounding

    /// Invoked when the algorithm wants an automatic dose enacted.
    /// iOS forwards to its `LoopDataManagerDelegate`; watch forwards to its
    /// own pump manager.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
                             completion: @escaping (LoopError?) -> Void)

    /// Pump-supported basal-rate rounding hook. Default returns the input
    /// unchanged.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBasalRate unitsPerHour: Double) -> Double

    /// Pump-supported bolus-volume rounding hook. Default returns the input
    /// unchanged.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBolusVolume units: Double) -> Double

    /// Estimated time the pump needs to deliver `units` (used by the missed-
    /// meal heuristic to predict whether a pending autobolus would mask a
    /// missed-meal signal).
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             estimateBolusDuration units: Double) -> TimeInterval?

    // MARK: Pump / CGM status snapshots (folded into StoredDosingDecision)

    /// The host pump-manager status, if available. Default `nil`.
    var pumpManagerStatusForRunner: PumpManagerStatus? { get }

    /// The host pump-manager status highlight, if available. Default `nil`.
    var pumpStatusHighlightForRunner: DeviceStatusHighlight? { get }

    /// The host CGM-manager status, if available. Default `nil`.
    var cgmManagerStatusForRunner: CGMManagerStatus? { get }

    // MARK: Missed-meal hand-off

    /// Invoked at the end of `finishLoop` when missed-meal detection is
    /// enabled, after the runner has fetched glucose effects and samples.
    /// iOS forwards to `MealDetectionManager.generateMissedMealNotificationIfNeeded`;
    /// watch may post a local notification or no-op.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             checkMissedMealWithGlucoseSamples glucoseSamples: [StoredGlucoseSample],
                             insulinCounteractionEffects: [GlucoseEffectVelocity],
                             carbEffects: [GlucoseEffect],
                             pendingAutobolusUnits: Double?)

    // MARK: Issue conversion hooks (host-rich `StoredDosingDecision.Issue` mapping)
    //
    // The runner persists errors and warnings into the dosing decision's
    // `errors` / `warnings` arrays. iOS Loop's host extensions
    // (`LoopError+Issue.swift`, `LoopWarning.issue`) provide a richer
    // `StoredDosingDecision.Issue(id:details:)` conversion than the
    // LAC-local stringification fallback. These hooks let the host plug
    // that conversion in. Default implementations preserve the LAC-local
    // minimal stringification so cross-platform callers (watch, tests)
    // don't have to implement them.

    /// Convert a `LoopError` to a host-rich `StoredDosingDecision.Issue`.
    /// iOS overrides to use `error.issue`; default returns a minimal
    /// stringified `Issue`.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor error: LoopError) -> StoredDosingDecision.Issue

    /// Convert a `LoopAlgorithmWarning` to a host-rich `StoredDosingDecision.Issue`.
    /// iOS overrides to use `LoopWarning.issue`; default returns a minimal
    /// stringified `Issue`.
    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor warning: LoopAlgorithmWarning) -> StoredDosingDecision.Issue
}

// MARK: - Default no-op implementations

public extension LoopAlgorithmRunnerDelegate {
    func loopAlgorithmRunnerDidStartLoop(_ runner: LoopAlgorithmRunner) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidComplete date: Date,
                             duration: TimeInterval) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             loopDidError error: LoopError,
                             duration: TimeInterval) {}

    func loopAlgorithmRunnerDidFinishLoop(_ runner: LoopAlgorithmRunner) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didChange context: LoopAlgorithmUpdateContext) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             settingsDidChange impact: LoopAlgorithmSettingsChangeImpact) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date),
                             completion: @escaping (LoopError?) -> Void) {
        completion(nil)
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBasalRate unitsPerHour: Double) -> Double {
        unitsPerHour
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             roundBolusVolume units: Double) -> Double {
        units
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             estimateBolusDuration units: Double) -> TimeInterval? {
        nil
    }

    var pumpManagerStatusForRunner: PumpManagerStatus? { nil }

    var pumpStatusHighlightForRunner: DeviceStatusHighlight? { nil }

    var cgmManagerStatusForRunner: CGMManagerStatus? { nil }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             checkMissedMealWithGlucoseSamples glucoseSamples: [StoredGlucoseSample],
                             insulinCounteractionEffects: [GlucoseEffectVelocity],
                             carbEffects: [GlucoseEffect],
                             pendingAutobolusUnits: Double?) {}

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor error: LoopError) -> StoredDosingDecision.Issue {
        StoredDosingDecision.Issue(id: String(describing: error))
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             issueFor warning: LoopAlgorithmWarning) -> StoredDosingDecision.Issue {
        StoredDosingDecision.Issue(id: String(describing: warning))
    }
}
