//
//  WatchAlgorithmBootstrap.swift
//  WatchApp Extension
//
//  Constructs `WatchAlgorithmDriver` when the handoff state machine reaches
//  `.watchDriver`; tears the driver down on state change. Idempotent on
//  repeated `.watchDriver` updates so spurious republishing doesn't churn.
//
//  Closures are used for stores + settings so the bootstrap can be wired
//  before its dependencies have fully initialized (e.g., before WCSession
//  has delivered the first phone-side settings sync).
//
//  B.3.a Phase 5. Phase 6: settingsProvider now returns `WatchSettingsSnapshot?`
//  OR `PhoneWatchSettingsSync?` (via the overload below).
//

#if !os(iOS)

import Foundation
import LoopAlgorithmCore
import LoopKit
import OmniBLE  // for HandoffState
import WatchAlgorithmKit  // for WatchAlgorithmDriver, WatchAlgorithmStores, WatchSettingsSnapshot

final class WatchAlgorithmBootstrap {

    /// The currently active driver, or nil when the watch is not the driver.
    /// `private(set)` for tests.
    private(set) var driver: WatchAlgorithmDriver?

    private let storesProvider: () -> WatchAlgorithmStores?
    private let settingsProvider: () -> WatchSettingsSnapshot?
    private let pumpManagerProvider: () -> PumpManager?  // B.6

    /// - Parameters:
    ///   - storesProvider: Returns the watch-side stores bundle, or nil if
    ///     the stores aren't ready (e.g., still initializing).
    ///   - settingsProvider: Returns the most recent settings snapshot, or
    ///     nil if no sync has been received yet.
    ///   - pumpManagerProvider: B.6 — Returns the watch-side OmniBLEPumpManager
    ///     (typed as PumpManager since that's what the algorithm enacts on),
    ///     or nil if not yet constructed. Defaulted to a nil-returning closure
    ///     so existing callers don't break.
    init(storesProvider: @escaping () -> WatchAlgorithmStores?,
         settingsProvider: @escaping () -> WatchSettingsSnapshot?,
         pumpManagerProvider: @escaping () -> PumpManager? = { nil }) {
        self.storesProvider = storesProvider
        self.settingsProvider = settingsProvider
        self.pumpManagerProvider = pumpManagerProvider
    }

    /// B.3.a Phase 6 convenience init: takes a `PhoneWatchSettingsSync`
    /// provider and converts to `WatchSettingsSnapshot` internally.
    /// B.6: also accepts a pumpManagerProvider with the same default.
    init(storesProvider: @escaping () -> WatchAlgorithmStores?,
         syncProvider: @escaping () -> PhoneWatchSettingsSync?,
         pumpManagerProvider: @escaping () -> PumpManager? = { nil }) {
        self.storesProvider = storesProvider
        self.settingsProvider = {
            guard let sync = syncProvider() else { return nil }
            return WatchSettingsSnapshot(fromSync: sync)
        }
        self.pumpManagerProvider = pumpManagerProvider
    }

    /// Updates the bootstrap in response to a handoff-state change.
    /// Idempotent: repeated `.watchDriver` updates do not rebuild the
    /// driver; non-driver states tear it down.
    func update(handoffState: HandoffState) {
        switch handoffState {
        case .watchDriver:
            startIfNeeded()
        case .phoneDriver, .recovering, .handoffPending:
            tearDown()
        }
    }

    // MARK: - Private

    private func startIfNeeded() {
        guard driver == nil else { return }
        guard let stores = storesProvider(),
              let settings = settingsProvider() else {
            // Stores or settings not ready yet; caller is expected to retry
            // when they become available (typically via another handoff
            // state republish).
            return
        }

        driver = WatchAlgorithmDriver(
            carbStore: stores.carbStore,
            doseStore: stores.doseStore,
            glucoseStore: stores.glucoseStore,
            dosingDecisionStore: stores.dosingDecisionStore,
            settingsSnapshot: settings,
            pumpManager: pumpManagerProvider()  // B.6: nil if not yet constructed
        )
    }

    private func tearDown() {
        driver = nil
    }
}

#endif  // !os(iOS)
