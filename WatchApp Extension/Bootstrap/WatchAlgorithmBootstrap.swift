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
//  B.3.a Phase 5.
//

#if !os(iOS)

import Foundation
import LoopAlgorithmCore
import LoopKit
import OmniBLE  // for HandoffState

/// Bundle of stores the algorithm needs. The watch already owns CarbStore +
/// GlucoseStore via `WatchContextManager`. DoseStore + DosingDecisionStore
/// are constructed on-demand by the caller.
struct WatchAlgorithmStores {
    let carbStore: CarbStoreProtocol
    let doseStore: DoseStoreProtocol
    let glucoseStore: GlucoseStoreProtocol
    let dosingDecisionStore: DosingDecisionStoreProtocol
}

final class WatchAlgorithmBootstrap {

    /// The currently active driver, or nil when the watch is not the driver.
    /// `private(set)` for tests.
    private(set) var driver: WatchAlgorithmDriver?

    private let storesProvider: () -> WatchAlgorithmStores?
    private let settingsProvider: () -> WatchSettingsSnapshot?

    /// - Parameters:
    ///   - storesProvider: Returns the watch-side stores bundle, or nil if
    ///     the stores aren't ready (e.g., still initializing).
    ///   - settingsProvider: Returns the most recent settings snapshot, or
    ///     nil if no sync has been received yet.
    init(storesProvider: @escaping () -> WatchAlgorithmStores?,
         settingsProvider: @escaping () -> WatchSettingsSnapshot?) {
        self.storesProvider = storesProvider
        self.settingsProvider = settingsProvider
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
            settingsSnapshot: settings
        )
    }

    private func tearDown() {
        driver = nil
    }
}

#endif  // !os(iOS)
