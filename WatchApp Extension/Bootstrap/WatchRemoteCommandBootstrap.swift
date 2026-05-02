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

    private let storesProvider: () -> WatchAlgorithmStores?
    private let settingsProvider: () -> WatchSettingsSnapshot?
    private let supportingStoresProvider: () -> WatchRemoteCommandStores?

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
    }

    /// Updates the bootstrap in response to a handoff-state change.
    func update(handoffState: HandoffState) {
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
    }

    private func tearDown() {
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
