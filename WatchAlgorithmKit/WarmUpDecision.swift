//
//  WarmUpDecision.swift
//  WatchAlgorithmKit
//
//  B.8: result type returned by `WarmUpDecider.decide(...)` (in the
//  WatchApp Extension target). The decision lives in WatchAlgorithmKit
//  because `WatchAlgorithmDriver.init(warmUpDecision:)` consumes it to
//  derive `isWarmingUp` at construction time, and the driver is in this
//  framework rather than in the extension target.
//
//  Keeping the type definitions here (and the pure-function `decide`
//  alongside the cache + freshness sources in the extension) preserves
//  the framework split: WatchAlgorithmKit owns runtime/data types,
//  WatchApp Extension owns I/O wiring.
//

import Foundation
import OmniBLE  // for AlgorithmStateSnapshot

public enum WarmUpDecision: Equatable {
    case skipWarmup(snapshot: AlgorithmStateSnapshot)
    case fullWarmup(failedGate: WarmUpGate)
}

/// Lettered prefixes (`a_`, `b_`, `c_`) preserve declaration order in
/// alphabetically-sorted log output and metric labels. Don't "fix" to
/// camelCase — the prefix is intentional.
public enum WarmUpGate: String, Equatable {
    case a_snapshotAge      // snapshot missing or > 6 min old
    case b_localCGM         // no local CGM read in last 5 min
    case c_pumpStatus       // no pump status reply in last 60 s
}
