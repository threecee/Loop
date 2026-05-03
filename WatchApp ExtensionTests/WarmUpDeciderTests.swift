//
//  WarmUpDeciderTests.swift
//

import XCTest
@testable import WatchApp_Extension
import OmniBLE

final class WarmUpDeciderTests: XCTestCase {

    private func makeSnapshot(createdAt: Date) -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: createdAt,
            phoneIterationDate: createdAt,
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 100,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: createdAt),
            activeOverride: nil
        )
    }

    func test_allGatesPass_returnsSkipWarmup() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now.addingTimeInterval(-60))
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now.addingTimeInterval(-60),
            latestPumpStatusDate: now.addingTimeInterval(-30)
        )
        guard case .skipWarmup = decision else {
            return XCTFail("All gates pass; expected skipWarmup, got \(decision)")
        }
    }

    func test_staleSnapshot_failsGateA() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now.addingTimeInterval(-7 * 60))   // > 6 min old
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now,
            latestPumpStatusDate: now
        )
        XCTAssertEqual(decision, .fullWarmup(failedGate: .a_snapshotAge))
    }

    func test_noLocalCGM_failsGateB() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now.addingTimeInterval(-60))
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: nil,
            latestPumpStatusDate: now
        )
        XCTAssertEqual(decision, .fullWarmup(failedGate: .b_localCGM))
    }

    func test_pumpStatusStale_failsGateC() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now.addingTimeInterval(-60))
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now,
            latestPumpStatusDate: now.addingTimeInterval(-90)   // > 60 s old
        )
        XCTAssertEqual(decision, .fullWarmup(failedGate: .c_pumpStatus))
    }

    func test_nilSnapshot_failsGateA() {
        let decision = WarmUpDecider.decide(
            now: Date(),
            snapshot: nil,
            latestLocalGlucoseDate: Date(),
            latestPumpStatusDate: Date()
        )
        XCTAssertEqual(decision, .fullWarmup(failedGate: .a_snapshotAge))
    }

    func test_snapshotExactlyAt6MinBoundary_passes() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now.addingTimeInterval(-6 * 60))
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now,
            latestPumpStatusDate: now
        )
        guard case .skipWarmup = decision else {
            return XCTFail("6 min exactly should pass; got \(decision)")
        }
    }

    func test_cgmExactlyAt5MinBoundary_passes() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now)
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now.addingTimeInterval(-5 * 60),
            latestPumpStatusDate: now
        )
        guard case .skipWarmup = decision else {
            return XCTFail("CGM at exactly 5 min should pass; got \(decision)")
        }
    }

    func test_pumpStatusExactlyAt60sBoundary_passes() {
        let now = Date()
        let snap = makeSnapshot(createdAt: now)
        let decision = WarmUpDecider.decide(
            now: now,
            snapshot: snap,
            latestLocalGlucoseDate: now,
            latestPumpStatusDate: now.addingTimeInterval(-60)
        )
        guard case .skipWarmup = decision else {
            return XCTFail("Pump status at exactly 60 s should pass; got \(decision)")
        }
    }
}
