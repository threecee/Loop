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
//  B.3.a Phase 5.
//

#if !os(iOS)

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

        // Phase 6 doesn't sync automaticDosingEnabled/isAutomaticDosingAllowed
        // yet (the PhoneWatchSettingsSync struct doesn't include them). Default
        // to false, which is conservative (watch will not auto-dose unless
        // a future sync adds these fields).
        self.automaticDosingEnabled = false
        self.isAutomaticDosingAllowed = false
    }

    struct NightscoutConfig {
        let siteURL: URL
        let apiSecret: String
    }
}

// MARK: - Driver

final class WatchAlgorithmDriver: NSObject {

    // MARK: Stored collaborators

    private let runner: LoopAlgorithmRunner
    private let settingsSnapshot: WatchSettingsSnapshot
    private let log = OSLog(subsystem: "com.loopkit.Loop.WatchApp", category: "WatchAlgorithmDriver")

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
         trustedTimeOffset: @escaping () -> TimeInterval = { 0 }) {
        self.settingsSnapshot = settingsSnapshot

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
    }

    // MARK: Test / introspection helpers

    /// Test-only access to the underlying runner. Phase-5 tests assert on
    /// "construction succeeded" rather than driving the algorithm; this
    /// accessor is intentionally minimal.
    var underlyingRunner: LoopAlgorithmRunner { runner }
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
        refreshComplications()
    }

    func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                             didChange context: LoopAlgorithmUpdateContext) {
        // Watch UI listens via its own publishers; no NotificationCenter
        // bridging is needed here. Logged for diagnostics.
        log.debug("WatchAlgorithmDriver: state changed (context=%{public}@)",
                  String(describing: context))
    }

    // The runner's default `settingsDidChange`, `didRecommend`, rounding,
    // and missed-meal hooks all default to no-op / pass-through, which is
    // the right behavior on watch for Phase 5. Phase 6+ will refine.

    // Issue conversion: defaults stringify, which is fine for watch.

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
