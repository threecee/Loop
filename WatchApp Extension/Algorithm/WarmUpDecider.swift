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

enum WarmUpDecision: Equatable {
    case skipWarmup(snapshot: AlgorithmStateSnapshot)
    case fullWarmup(failedGate: WarmUpGate)
}

/// Lettered prefixes (`a_`, `b_`, `c_`) preserve declaration order in
/// alphabetically-sorted log output and metric labels. Don't "fix" to
/// camelCase — the prefix is intentional.
enum WarmUpGate: String, Equatable {
    case a_snapshotAge      // snapshot missing or > 6 min old
    case b_localCGM         // no local CGM read in last 5 min
    case c_pumpStatus       // no pump status reply in last 60 s
}

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
