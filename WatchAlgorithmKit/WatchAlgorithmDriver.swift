//
//  WatchAlgorithmDriver.swift
//  WatchAlgorithmKit
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
//  B.6 Phase 4a-bis: extracted into WatchAlgorithmKit framework so OmniBLETests
//  (iOS) can link this code for Phase 4b's integration test.
//

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
#if os(watchOS)
import ClockKit
#endif

// MARK: - Settings snapshot

/// A read-only snapshot of the most recent settings the watch has received
/// from the phone. Used by `WatchAlgorithmDriver` adapters and by the
/// Phase 5 bootstraps. Phase 6 populates via `PhoneWatchSettingsSync` (see
/// `init(fromSync:)` below); Phase 5 tests still construct it directly.
public final class WatchSettingsSnapshot {

    /// The most recent `LoopSettings` synced from the phone.
    public let loopSettings: LoopSettings

    /// The most recent `StoredSettings` snapshot synced from the phone.
    public let storedSettings: StoredSettings

    /// Nightscout configuration (URL + API secret) if the phone has
    /// configured one. `nil` means "do not start RemoteDataServicesManager
    /// against Nightscout."
    public let nightscoutConfig: NightscoutConfig?

    /// Whether the phone has automatic dosing turned on.
    public let automaticDosingEnabled: Bool

    /// Whether automatic dosing is currently allowed (not blocked by, e.g.,
    /// a pump comms failure).
    public let isAutomaticDosingAllowed: Bool

    public init(loopSettings: LoopSettings = LoopSettings(),
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
    public init(fromSync sync: PhoneWatchSettingsSync) {
        // B.5.2 Issue #3: resolve schedule zone from the sync payload (the
        // phone's TimeZone.current at emission time). Fall back to the watch's
        // own TimeZone.current when the sync didn't include a zone (v3 senders
        // before the field was added) or when the identifier was unrecognized.
        // Schedules use this zone to interpret `RepeatingScheduleValue` startTime
        // offsets (seconds-from-midnight in WHICH zone) — without alignment, the
        // watch's basal/ISF/CR/target lookups would drift relative to the phone
        // when the two devices report different zones.
        let scheduleZone = sync.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone.current

        let basalSchedule = sync.basalScheduleItems.isEmpty ? nil
            : BasalRateSchedule(dailyItems: sync.basalScheduleItems, timeZone: scheduleZone)
        let isfSchedule = sync.insulinSensitivityScheduleItems.isEmpty ? nil
            : InsulinSensitivitySchedule(unit: .milligramsPerDeciliter,
                                         dailyItems: sync.insulinSensitivityScheduleItems,
                                         timeZone: scheduleZone)
        let carbSchedule = sync.carbRatioScheduleItems.isEmpty ? nil
            : CarbRatioSchedule(unit: .gram(),
                                dailyItems: sync.carbRatioScheduleItems,
                                timeZone: scheduleZone)
        let targetSchedule = sync.glucoseTargetRangeScheduleItems.isEmpty ? nil
            : GlucoseRangeSchedule(unit: .milligramsPerDeciliter,
                                   dailyItems: sync.glucoseTargetRangeScheduleItems,
                                   timeZone: scheduleZone)
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

    public struct NightscoutConfig {
        public let siteURL: URL
        public let apiSecret: String

        public init(siteURL: URL, apiSecret: String) {
            self.siteURL = siteURL
            self.apiSecret = apiSecret
        }
    }
}

// MARK: - Suppression reasons (B.6)

/// Why a watch-side automatic dose was suppressed instead of enacted.
/// Persisted into `StoredDosingDecision.reason` so the iOS event log
/// shows why the watch decided not to dose. Reason strings are namespaced
/// with `watchSuppressed.` to disambiguate from iOS's bare-string reasons
/// like `"loop"` / `"getLoopState"` (per Phase 1 discovery).
public enum WatchDoseSuppressionReason: String {
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

public final class WatchAlgorithmDriver: NSObject, ObservableObject {

    // MARK: Stored collaborators

    private let runner: LoopAlgorithmRunner
    private let settingsSnapshot: WatchSettingsSnapshot
    private let log = OSLog(subsystem: "com.loopkit.Loop.WatchApp", category: "WatchAlgorithmDriver")

    /// B.8.4: stores retained for snapshot hydration in the `.skipWarmup`
    /// path. The runner already holds its own references; these handles let
    /// `applyAlgorithmStateSnapshot(_:into:)` write directly to the same
    /// instances without re-plumbing through the runner.
    private let carbStore: CarbStoreProtocol
    private let doseStore: DoseStoreProtocol
    private let glucoseStore: GlucoseStoreProtocol

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

    /// B.6: Held strong so suppression decisions can include the same
    /// battery / charging context as non-suppressed decisions (per
    /// Phase 1 discovery point #4 — analytic parity). The runner also
    /// uses this same instance via the provider-protocol bridge.
    private let controllerStatusAdapter: WatchControllerStatusAdapter

    /// B.5: UserDefaults handle used by the dose recovery tripwire. In
    /// production this is the App Group defaults (so ExtensionDelegate's
    /// launch-time stale check sees the entry). Tests pass an isolated
    /// suite-named defaults to verify the recordStart/clear lifecycle.
    private let recoveryDefaults: UserDefaults?

    // MARK: Warm-up tracking (B.3.a Phase 7)

    /// True from construction until the runner completes its first full loop
    /// iteration after handoff. During this window the algorithm's CoreData
    /// stores are still backfilling from the G7 sensor and pod history, so
    /// predictions are limited.
    @Published public private(set) var isWarmingUp: Bool = true
    private var didCompleteFirstIteration = false

    // MARK: Construction

    /// Builds a `LoopAlgorithmRunner` against the supplied watch-side stores.
    /// The driver retains the runner and serves as its delegate plus all
    /// three provider protocols.
    public init(carbStore: CarbStoreProtocol,
                doseStore: DoseStoreProtocol,
                glucoseStore: GlucoseStoreProtocol,
                dosingDecisionStore: DosingDecisionStoreProtocol,
                settingsSnapshot: WatchSettingsSnapshot,
                pumpInsulinType: InsulinType? = nil,
                now: @escaping () -> Date = { Date() },
                trustedTimeOffset: @escaping () -> TimeInterval = { 0 },
                pumpManager: PumpManager? = nil,                    // B.6: dose-emission target (nil → suppress all)
                isWarmingUpOverride: Bool? = nil,                   // B.6: test-only override
                recoveryDefaults: UserDefaults? = nil,              // B.5: dose recovery tripwire defaults (nil → resolve App Group at use)
                /// B.8: optional warmup decision. When non-nil and
                /// `isWarmingUpOverride` is nil, the init derives `isWarmingUp`
                /// (and `didCompleteFirstIteration`) from this decision.
                /// **Ignored when `isWarmingUpOverride` is non-nil** — the B.6
                /// test override always wins.
                warmUpDecision: WarmUpDecision? = nil) {
        self.settingsSnapshot = settingsSnapshot
        self.pumpManager = pumpManager
        self.dosingDecisionStore = dosingDecisionStore
        self.isWarmingUpOverride = isWarmingUpOverride
        self.recoveryDefaults = recoveryDefaults
        // B.8.4: retain store references so the .skipWarmup hydration path
        // can write the snapshot's buffers without re-routing through the
        // runner. The runner gets its own copies below.
        self.carbStore = carbStore
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore

        // B.6 Phase 4c: copy schedules from settings to doseStore so the
        // algorithm runner can read them. LoopAlgorithmRunner reads
        // `basalProfileApplyingOverrideHistory` and `insulinSensitivitySchedule`
        // from the DoseStore, NOT from the LoopSettings struct — so without
        // this copy, the runner errors with
        // configurationError(.basalRateSchedule) and never produces a
        // recommendation (silent failure). Discovered during Phase 4b
        // integration test development.
        //
        // Idempotent — if some other code path also sets these (e.g., a
        // future CoreData restore, or LoopAlgorithmRunner.settingsDidChange),
        // the copy just re-assigns the same values. iOS production sets these
        // via LoopAlgorithmRunner.swift:488-500 (settings observer); the
        // watch's defensive init copy ensures correctness regardless of
        // whether that observer fires before the first loop tick.
        if let basalProfile = settingsSnapshot.loopSettings.basalRateSchedule {
            doseStore.basalProfile = basalProfile
        }
        if let isfSchedule = settingsSnapshot.loopSettings.insulinSensitivitySchedule {
            doseStore.insulinSensitivitySchedule = isfSchedule
        }

        // Provider conformances live on `self`, but `self` isn't fully
        // initialized yet. Construct lightweight adapter shims that hold weak
        // references back to the driver, then resolve them at first call.
        let controllerStatusAdapter = WatchControllerStatusAdapter()
        self.controllerStatusAdapter = controllerStatusAdapter
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

        // B.8: derive isWarmingUp from WarmUpDecider's verdict when provided.
        // The B.6 isWarmingUpOverride takes precedence (test path); production
        // callers pass warmUpDecision and leave isWarmingUpOverride nil.
        // Setting didCompleteFirstIteration=true on .skipWarmup short-circuits
        // the "first iteration just completed → flip isWarmingUp to false"
        // notification path (mirrors the override-false branch above).
        #if DEBUG
        if isWarmingUpOverride != nil, warmUpDecision != nil {
            assertionFailure("WatchAlgorithmDriver: both isWarmingUpOverride and warmUpDecision passed — override wins, decision ignored. Pick one.")
        }
        #endif
        if isWarmingUpOverride == nil, let decision = warmUpDecision {
            switch decision {
            case .skipWarmup(let snapshot):
                // B.8.4: hydrate stores from snapshot before flipping out of
                // warmup. Pediatric T1D safety: prefer warmup over potentially
                // stale state. Worst case during the brief async hydration
                // window is "extra warmup time" — never "premature dosing"
                // because isWarmingUp defaults to true and only flips to false
                // on hydration success.
                guard snapshot.isFreshEnoughForSkipWarmup() else {
                    let ageSec = Date().timeIntervalSince(snapshot.phoneIterationDate)
                    log.error("Snapshot too old (%{public}.0fs); rejecting skip-warmup, falling back to full warmup",
                              ageSec)
                    self.isWarmingUp = true
                    self.didCompleteFirstIteration = false
                    break
                }
                let carbStoreRef = self.carbStore
                let doseStoreRef = self.doseStore
                let glucoseStoreRef = self.glucoseStore
                Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await Self.applyAlgorithmStateSnapshot(
                            snapshot,
                            carbStore: carbStoreRef,
                            doseStore: doseStoreRef,
                            glucoseStore: glucoseStoreRef
                        )
                        await MainActor.run {
                            self.isWarmingUp = false
                            self.didCompleteFirstIteration = true
                        }
                        self.log.default(
                            "skipWarmup: hydrated %{public}d glucose / %{public}d dose / %{public}d carb entries from snapshot %{public}@",
                            snapshot.glucoseSamples.count,
                            snapshot.doseHistory.count,
                            snapshot.carbEntries.count,
                            snapshot.snapshotID.uuidString
                        )
                    } catch {
                        self.log.error("Snapshot hydration failed; remaining in warmup: %{public}@",
                                       String(describing: error))
                        // Don't flip flags — driver stays in warmup state (safe default).
                    }
                }
            case .fullWarmup:
                self.isWarmingUp = true
                self.didCompleteFirstIteration = false
            }
        }
    }

    // MARK: - B.8.4 snapshot hydration

    /// Writes the snapshot's glucose / dose / carb buffers into the supplied
    /// stores. Called from the `.skipWarmup` switch case in `init` (via a
    /// detached Task) so the watch can dose immediately after handoff without
    /// waiting for a fresh round-trip through the algorithm's first warm-up
    /// iteration.
    ///
    /// Projection rules (Stored → New, per Phase 1 discovery):
    /// - `StoredGlucoseSample → NewGlucoseSample`: trivial field mapping;
    ///   `syncIdentifier` falls back to a fresh UUID for de-dup safety when
    ///   the stored value is `nil`, and `syncVersion` defaults to 1.
    /// - `[DoseEntry]`: passes through unchanged via `DoseStoreProtocol.addDoses`.
    /// - `StoredCarbEntry → NewCarbEntry`: trivial mapping; `CarbStoreProtocol`
    ///   has no batch insert, so each entry is added sequentially.
    static func applyAlgorithmStateSnapshot(
        _ snapshot: AlgorithmStateSnapshot,
        carbStore: CarbStoreProtocol,
        doseStore: DoseStoreProtocol,
        glucoseStore: GlucoseStoreProtocol
    ) async throws {
        // 1. Glucose — projection required.
        let newGlucoseSamples: [NewGlucoseSample] = snapshot.glucoseSamples.map { stored in
            NewGlucoseSample(
                date: stored.startDate,
                quantity: stored.quantity,
                condition: stored.condition,
                trend: stored.trend,
                trendRate: stored.trendRate,
                isDisplayOnly: stored.isDisplayOnly,
                wasUserEntered: stored.wasUserEntered,
                syncIdentifier: stored.syncIdentifier ?? UUID().uuidString,
                syncVersion: stored.syncVersion ?? 1,
                device: stored.device
            )
        }
        if !newGlucoseSamples.isEmpty {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                glucoseStore.addGlucoseSamples(newGlucoseSamples) { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }

        // 2. Dose — pass-through, no projection.
        //
        // `DoseStore.addDoses` calls its completion handler TWICE on the
        // success path: once when the dose entries land, then again after
        // `syncPumpEventsToInsulinDeliveryStore` runs (LoopKit
        // DoseStore.swift:856-858). Guard against double-resumption of the
        // continuation by latching a single-shot resume; otherwise we crash
        // with "SWIFT TASK CONTINUATION MISUSE" on every non-empty
        // doseHistory hydration. Only the FIRST completion is consumed.
        if !snapshot.doseHistory.isEmpty {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let lock = NSLock()
                var didResume = false
                doseStore.addDoses(snapshot.doseHistory, from: nil) { error in
                    lock.lock()
                    let alreadyResumed = didResume
                    didResume = true
                    lock.unlock()
                    guard !alreadyResumed else { return }
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        // 3. Carbs — singular insert; loop sequentially.
        for stored in snapshot.carbEntries {
            let newEntry = NewCarbEntry(
                date: stored.userCreatedDate ?? stored.startDate,
                quantity: stored.quantity,
                startDate: stored.startDate,
                foodType: stored.foodType,
                absorptionTime: stored.absorptionTime
            )
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                carbStore.addCarbEntry(newEntry) { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: Test / introspection helpers

    /// Test-only access to the underlying runner. Phase-5 tests assert on
    /// "construction succeeded" rather than driving the algorithm; this
    /// accessor is intentionally minimal.
    public var underlyingRunner: LoopAlgorithmRunner { runner }

    #if DEBUG
    /// B.8.4 Phase 5b: re-runs the watch's algorithm against a captured input
    /// (the wrapper Phase 5a introduced) and returns the produced output in
    /// the same wrapper shape. Used by `LoopAlgorithmReconciliationTests` to
    /// assert byte-identical behavior between the iOS `LoopAlgorithmRunner`
    /// (which produced the captured `expectedOutput`) and the watch's runner
    /// invocation path on the same input.
    ///
    /// **Current status — placeholder.** Fully reconstructing a runner from a
    /// `CapturedAlgorithmInput` requires settings + stores + provider shims
    /// that the wrapper deliberately does NOT carry (per Phase 5a's design
    /// note: the wrapper holds the predictionInput, not the full driver
    /// surroundings). The reconciliation test target ships in a stub form:
    /// the harness exists, the 3 scenarios are wired, but the actual replay
    /// throws `ReconciliationUnsupported.requiresFullerFixture` so callers
    /// `XCTSkip`. Carl extends the wrapper + this helper in a follow-up once
    /// real captures land in `LoopAlgorithmReconciliationTests/Fixtures/`.
    ///
    /// The signature is locked: `CapturedAlgorithmInput → CapturedAlgorithmOutput`.
    /// Future implementations replace the body without touching the test.
    public static func runForReconciliation(_ input: CapturedAlgorithmInput) throws -> CapturedAlgorithmOutput {
        throw ReconciliationUnsupported.requiresFullerFixture
    }

    /// B.8.4 Phase 5b: error type signaling the reconciliation harness can't
    /// yet replay this fixture (the wrapper doesn't carry enough state to
    /// reconstruct a `LoopAlgorithmRunner`). The test target translates this
    /// into `XCTSkip` so CI stays green while real captures + a fuller
    /// reconstruction path are still in flight.
    public enum ReconciliationUnsupported: Error, CustomStringConvertible {
        case requiresFullerFixture

        public var description: String {
            switch self {
            case .requiresFullerFixture:
                return "WatchAlgorithmDriver.runForReconciliation: wrapper-only fixture cannot reconstruct a runner; awaiting fuller capture format (B.8.4 Phase 5b stub)"
            }
        }
    }
    #endif
}

// MARK: - Notification names (B.3.a Phase 7)

extension WatchAlgorithmDriver {
    /// Posted on the main queue when `isWarmingUp` transitions from `true` to
    /// `false` (i.e., the runner has completed its first full iteration after
    /// handoff). `object` is the `WatchAlgorithmDriver` instance.
    public static let warmUpDidCompleteNotification = Notification.Name(
        "com.loopkit.Loop.WatchAlgorithmDriver.warmUpDidComplete"
    )
}

// MARK: - LoopAlgorithmRunnerDelegate (watch orchestration)

extension WatchAlgorithmDriver: LoopAlgorithmRunnerDelegate {

    public func loopAlgorithmRunnerDidStartLoop(_ runner: LoopAlgorithmRunner) {
        log.default("WatchAlgorithmDriver: loop iteration starting")
    }

    public func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                                    loopDidComplete date: Date,
                                    duration: TimeInterval) {
        log.default("WatchAlgorithmDriver: loop completed in %{public}.2fs", duration)
    }

    public func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
                                    loopDidError error: LoopError,
                                    duration: TimeInterval) {
        log.error("WatchAlgorithmDriver: loop errored after %{public}.2fs: %{public}@",
                  duration, String(describing: error))
    }

    public func loopAlgorithmRunnerDidFinishLoop(_ runner: LoopAlgorithmRunner) {
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

    public func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
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
    // CRITICAL: completion(nil) is load-bearing on the NON-RETRYABLE
    // suppression paths (gates 1-4). LoopAlgorithmRunner only clears its
    // cached recommendedAutomaticDose when the delegate completion is
    // called with nil; calling with an error (or skipping completion)
    // would cause the algorithm to retry the same recommendation on the
    // next tick. (Phase 1 discovery.)
    //
    // Gate 5 (delivery-uncertain) is the exception — it INTENTIONALLY
    // returns LoopError.connectionError because delivery-uncertain is
    // transient and we WANT the algorithm to retry next tick when the
    // pump state may have settled. Don't change gate 5's completion
    // without re-reading iOS DeviceDataManager.swift:1416.
    public func loopAlgorithmRunner(_ runner: LoopAlgorithmRunner,
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

        // Gate 5: pump reports delivery state is uncertain (e.g., last
        // command's ack was lost, BLE reconnect mid-bolus). Mirror iOS
        // DeviceDataManager.swift:1416 — return a RETRYABLE error so the
        // algorithm will try again next tick when state may have settled,
        // rather than firing on top of an unconfirmed dose. NOTE: this is
        // the one suppression path that does NOT call completion(nil) —
        // see header comment about completion(nil)'s load-bearing role on
        // non-retryable paths. delivery-uncertain is transient → retry.
        guard !pumpManager.status.deliveryIsUncertain else {
            log.error("WatchAlgorithmDriver: suppressing dose — pump delivery state uncertain")
            completion(LoopError.connectionError)
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
        // B.6: enrich with controller status so suppression decisions
        // are queryable with the same battery context as non-suppressed
        // decisions (Phase 1 discovery point #4).
        decision.controllerStatus = controllerStatusAdapter.controllerStatus
        return decision
    }

    /// Mirrors iOS `DoseEnactor.enact(...)` inline (DoseEnactor lives in iOS
    /// Loop target only; not shared). Temp basal first, then bolus, both via
    /// DispatchGroup. Result is a single LoopError? — the first failure
    /// short-circuits.
    ///
    /// B.5: dose enactment is bracketed by WatchDoseRecoveryStore which
    /// records "dose in flight" to App Group UserDefaults before the BLE
    /// command and clears after completion. On watch app launch,
    /// ExtensionDelegate checks for stale entries and logs them. NOT a
    /// full iOS-style CrashRecoveryManager analog (no retry/cancel/reconcile
    /// flow); just a tripwire so we know a dose may have been interrupted
    /// and the pod's own history is the source of truth.
    private func enactRecommendedDose(
        _ recommendation: AutomaticDoseRecommendation,
        with pumpManager: PumpManager,
        completion: @escaping (LoopError?) -> Void
    ) {
        // B.5: record dose-in-flight tripwire BEFORE BLE command. Cleared
        // in completion (both success + error branches, including the
        // early-return temp basal error path).
        let defaults = recoveryDefaults ?? HandoffSettings.appGroupDefaults
        WatchDoseRecoveryStore.recordStart(
            description: String(describing: recommendation),
            to: defaults
        )

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
                WatchDoseRecoveryStore.clear(from: defaults)  // B.5
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
            WatchDoseRecoveryStore.clear(from: defaults)  // B.5
            completion(bolusError.map { .pumpManagerError($0) })
        }
    }

    // MARK: Watch-specific helpers

    private func refreshComplications() {
        // CLKComplicationServer is part of ClockKit but is marked unavailable
        // on iOS — gate on os(watchOS) rather than canImport(ClockKit).
        #if os(watchOS)
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
