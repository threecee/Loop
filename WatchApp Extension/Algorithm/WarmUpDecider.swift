//
//  WarmUpDecider.swift
//  WatchApp Extension
//
//  B.8: pure-function decision invoked once at WatchAlgorithmDriver init.
//  Reads the cached snapshot + injected freshness inputs, applies three
//  independent gates, returns whether to skip warmup or fall back to today's
//  full warmup behavior.
//

#if !os(iOS)

import Foundation
import OmniBLE
import WatchAlgorithmKit  // for WarmUpDecision / WarmUpGate (B.8 T11 relocation)

enum WarmUpDecider {

    static let snapshotMaxAge: TimeInterval = 6 * 60
    static let cgmMaxAge: TimeInterval = 5 * 60
    static let pumpStatusMaxAge: TimeInterval = 60

    /// Pure decision. All freshness inputs are passed in; this function
    /// performs no I/O. Caller is responsible for resolving the latest
    /// CGM / pump-status timestamps from their respective sources.
    static func decide(now: Date,
                       snapshot: AlgorithmStateSnapshot?,
                       latestLocalGlucoseDate: Date?,
                       latestPumpStatusDate: Date?) -> WarmUpDecision {
        // Gate A: snapshot present and fresh.
        guard let snapshot,
              now.timeIntervalSince(snapshot.createdAt) <= snapshotMaxAge
        else {
            return .fullWarmup(failedGate: .a_snapshotAge)
        }
        // Gate B: at least one local CGM read in the last 5 min.
        guard let cgmDate = latestLocalGlucoseDate,
              now.timeIntervalSince(cgmDate) <= cgmMaxAge
        else {
            return .fullWarmup(failedGate: .b_localCGM)
        }
        // Gate C: pump status reply received in the last 60 s.
        guard let pumpDate = latestPumpStatusDate,
              now.timeIntervalSince(pumpDate) <= pumpStatusMaxAge
        else {
            return .fullWarmup(failedGate: .c_pumpStatus)
        }
        return .skipWarmup(snapshot: snapshot)
    }
}

#endif  // !os(iOS)
