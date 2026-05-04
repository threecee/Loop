//
//  WatchRemoteCommandBootstrap.swift
//  WatchApp Extension
//
//  Constructs `RemoteDataServicesManager` and statically registers
//  `NightscoutService` (per the Phase 3 static-link path) when the watch
//  becomes the driver. Gated on `nightscoutConfig != nil` — if the user
//  has not configured Nightscout on the phone, polling does not run on
//  the watch either.
//
//  B.3.a Phase 5.
//

#if !os(iOS)

import Foundation
import Combine
import LoopKit
import NightscoutServiceKit
import OmniBLE  // for HandoffState
import WatchAlgorithmKit  // for WatchAlgorithmStores, WatchSettingsSnapshot (B.6 Phase 4a-bis)

final class WatchRemoteCommandBootstrap {

    /// The currently active manager, or nil when the watch is not the driver
    /// or Nightscout isn't configured. `private(set)` for tests.
    private(set) var manager: RemoteDataServicesManager?

    /// The Nightscout service registered with `manager`, if any. Tests
    /// inspect this to assert the gating logic.
    private(set) var nightscoutService: NightscoutService?

    /// B.11.1: RemoteCareUploader registered with HandoffOrchestrator
    /// when the watch is driver. Owned here (lifetime tracks the
    /// bootstrap's RDSM); orchestrator holds a weak reference. Cleared
    /// on `tearDown()` so a phone-driver state doesn't keep a stale
    /// uploader pointed at a torn-down RDSM.
    private(set) var remoteCareUploader: LoopRemoteCareUploader?

    private let storesProvider: () -> WatchAlgorithmStores?
    private let settingsProvider: () -> WatchSettingsSnapshot?
    private let supportingStoresProvider: () -> WatchRemoteCommandStores?

    /// tracks the most recent handoff state so `retryIfNeeded()`
    /// (publisher sink) can short-circuit unless we're in `.watchDriver`.
    private var lastHandoffState: HandoffState = .phoneDriver

    /// subscription to `WatchSettingsCache.shared.publisher`. Holds
    /// the cancellable so the bootstrap's lifetime governs the subscription.
    private var settingsCancellable: AnyCancellable?

    /// - Parameters:
    ///   - storesProvider: Returns the same stores bundle used by the
    ///     algorithm (CarbStore + GlucoseStore + DoseStore + DosingDecisionStore).
    ///   - supportingStoresProvider: Returns the additional stores
    ///     `RemoteDataServicesManager` requires beyond the algorithm bundle
    ///     (InsulinDeliveryStore, SettingsStore, CgmEventStore).
    ///   - settingsProvider: Returns the most recent settings snapshot.
    init(storesProvider: @escaping () -> WatchAlgorithmStores?,
         supportingStoresProvider: @escaping () -> WatchRemoteCommandStores?,
         settingsProvider: @escaping () -> WatchSettingsSnapshot?) {
        self.storesProvider = storesProvider
        self.supportingStoresProvider = supportingStoresProvider
        self.settingsProvider = settingsProvider
        // re-attempt startIfNeeded() on any settings arrival. Gated on
        // lastHandoffState == .watchDriver inside retryIfNeeded() so a settings
        // arrival in .phoneDriver doesn't inappropriately build a manager.
        settingsCancellable = WatchSettingsCache.shared.publisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.retryIfNeeded() }
            }
    }

    /// B.3.a Phase 6 convenience init: takes a `PhoneWatchSettingsSync`
    /// provider and converts to `WatchSettingsSnapshot` internally.
    init(storesProvider: @escaping () -> WatchAlgorithmStores?,
         supportingStoresProvider: @escaping () -> WatchRemoteCommandStores?,
         syncProvider: @escaping () -> PhoneWatchSettingsSync?) {
        self.storesProvider = storesProvider
        self.supportingStoresProvider = supportingStoresProvider
        self.settingsProvider = {
            guard let sync = syncProvider() else { return nil }
            return WatchSettingsSnapshot(fromSync: sync)
        }
        // re-attempt startIfNeeded() on any settings arrival. Gated on
        // lastHandoffState == .watchDriver inside retryIfNeeded() so a settings
        // arrival in .phoneDriver doesn't inappropriately build a manager.
        settingsCancellable = WatchSettingsCache.shared.publisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.retryIfNeeded() }
            }
    }

    /// Updates the bootstrap in response to a handoff-state change.
    /// B.11.1: now `@MainActor` because `startIfNeeded()` mutates
    /// `HandoffOrchestrator.shared` (a MainActor-isolated property). The
    /// caller (`ExtensionDelegate`) already dispatches on main queue, so
    /// no callers break.
    @MainActor
    func update(handoffState: HandoffState) {
        // record before delegating so retryIfNeeded() (publisher sink)
        // gates correctly on the most recent state.
        lastHandoffState = handoffState
        switch handoffState {
        case .watchDriver:
            startIfNeeded()
        case .phoneDriver, .recovering, .handoffPending:
            tearDown()
        }
    }

    /// Triggers an upload pass on every registered remote-data service.
    /// `BackgroundPollScheduler` calls this on background-task wake.
    /// No-op when `manager == nil` (watch isn't driver, or no NS config).
    func triggerPollIfActive() {
        guard let manager = manager else { return }
        // RemoteDataServicesManager doesn't currently expose a single
        // "poll all" entry point on watch (Phase 6 may add one). Instead
        // we trigger the data types that matter for inbound remote
        // commands — Nightscout's `RemoteCommandSourceV1` is driven by
        // the service's own polling, not by RDSM uploads. For now this
        // is a no-op stub so the wiring is in place.
        _ = manager
    }

    // MARK: - Private

    /// settings publisher subscription target. Gated on
    /// `lastHandoffState == .watchDriver` so a settings arrival in any other
    /// state doesn't inappropriately build a manager.
    @MainActor
    private func retryIfNeeded() {
        guard case .watchDriver = lastHandoffState else { return }
        startIfNeeded()
    }

    @MainActor
    private func startIfNeeded() {
        guard manager == nil else { return }
        guard let settings = settingsProvider(),
              settings.nightscoutConfig != nil else {
            // No Nightscout config -> nothing to do (per the user's
            // "if Nightscout not configured, polling doesn't run" guard).
            return
        }
        guard let stores = storesProvider(),
              let supporting = supportingStoresProvider() else {
            return
        }

        let mgr = RemoteDataServicesManager(
            carbStore: stores.carbStore as! CarbStore,
            doseStore: stores.doseStore as! DoseStore,
            dosingDecisionStore: stores.dosingDecisionStore as! DosingDecisionStore,
            glucoseStore: stores.glucoseStore as! GlucoseStore,
            cgmEventStore: supporting.cgmEventStore,
            settingsStore: supporting.settingsStore,
            overrideHistory: supporting.overrideHistory,
            insulinDeliveryStore: supporting.insulinDeliveryStore
        )

        // Static-link path established in Phase 3: NightscoutServiceKit is
        // statically linked into the watch extension (no PluginManager).
        // Construct the service and seed credentials from the synced config.
        let svc = NightscoutService()
        if let ns = settings.nightscoutConfig {
            svc.siteURL = ns.siteURL
            svc.apiSecret = ns.apiSecret
        }
        mgr.addService(svc)

        self.manager = mgr
        self.nightscoutService = svc

        // B.11.1: register the watch-side RemoteCareUploader with the
        // orchestrator. Same wrapper class as iOS — the static-link path
        // (B.3.a Phase 3) makes NightscoutServiceKit available here, so we
        // reuse LoopRemoteCareUploader unchanged. The orchestrator's role
        // gate + quiesce-on-handoff semantics now apply to the watch's
        // upload triggers.
        let uploader = LoopRemoteCareUploader(
            triggerUpload: { [weak mgr] type in
                mgr?.triggerUpload(for: type)
            })
        self.remoteCareUploader = uploader
        HandoffOrchestrator.shared?.remoteCareUploader = uploader
    }

    @MainActor
    private func tearDown() {
        // B.11.1: clear orchestrator's weak reference and our owned
        // reference so a phone-driver state doesn't keep a stale uploader
        // pointed at a torn-down RDSM.
        HandoffOrchestrator.shared?.remoteCareUploader = nil
        remoteCareUploader = nil
        manager = nil
        nightscoutService = nil
    }
}

// MARK: - Supporting stores bundle

/// Stores `RemoteDataServicesManager` needs beyond the algorithm core's
/// `WatchAlgorithmStores`. Owned by the host (`ExtensionDelegate`) so they
/// outlive transient driver/manager teardown.
struct WatchRemoteCommandStores {
    let cgmEventStore: CgmEventStore
    let settingsStore: SettingsStore
    let overrideHistory: TemporaryScheduleOverrideHistory
    let insulinDeliveryStore: InsulinDeliveryStore
}

#endif  // !os(iOS)
