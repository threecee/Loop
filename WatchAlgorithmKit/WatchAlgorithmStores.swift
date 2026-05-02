//
//  WatchAlgorithmStores.swift
//  WatchAlgorithmKit
//
//  Bundle of stores the algorithm needs. Extracted from
//  WatchAlgorithmBootstrap during B.6 framework split so OmniBLETests
//  can construct one for the integration test.
//

import Foundation
import LoopAlgorithmCore

public struct WatchAlgorithmStores {
    public let carbStore: CarbStoreProtocol
    public let doseStore: DoseStoreProtocol
    public let glucoseStore: GlucoseStoreProtocol
    public let dosingDecisionStore: DosingDecisionStoreProtocol

    public init(
        carbStore: CarbStoreProtocol,
        doseStore: DoseStoreProtocol,
        glucoseStore: GlucoseStoreProtocol,
        dosingDecisionStore: DosingDecisionStoreProtocol
    ) {
        self.carbStore = carbStore
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.dosingDecisionStore = dosingDecisionStore
    }
}
