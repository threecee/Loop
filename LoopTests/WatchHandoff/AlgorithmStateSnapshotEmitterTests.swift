//
//  AlgorithmStateSnapshotEmitterTests.swift
//  LoopTests
//

import XCTest
import LoopKit
import OmniBLE
@testable import Loop

final class AlgorithmStateSnapshotEmitterTests: XCTestCase {

    private final class CapturingTransport: SnapshotTransport {
        var sent: [PhoneWatchMessage] = []
        func send(_ message: PhoneWatchMessage) { sent.append(message) }
    }

    func test_emit_sendsAlgorithmStateSnapshotMessage() {
        let transport = CapturingTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pumpStatus = PumpStatusSnapshot(reservoirUnitsRemaining: 50,
                                            lastBasalRateUnitsPerHour: 0.5,
                                            isSuspended: false,
                                            lastReadingDate: now)
        let emitter = AlgorithmStateSnapshotEmitter(
            transport: transport,
            now: { now },
            stateProvider: {
                AlgorithmStateSnapshotEmitter.State(
                    iterationDate: now,
                    glucoseSamples: [],
                    doseHistory: [],
                    carbEntries: [],
                    pumpStatus: pumpStatus,
                    activeOverride: nil
                )
            }
        )
        emitter.emit()
        XCTAssertEqual(transport.sent.count, 1)
        guard case .algorithmStateSnapshot(let snap) = transport.sent.first else {
            return XCTFail("Expected .algorithmStateSnapshot")
        }
        XCTAssertEqual(snap.createdAt, now)
        XCTAssertEqual(snap.phoneIterationDate, now)
        XCTAssertEqual(snap.pumpStatus, pumpStatus)
    }

    func test_emit_isNoOpWhenStateProviderReturnsNil() {
        let transport = CapturingTransport()
        let emitter = AlgorithmStateSnapshotEmitter(
            transport: transport,
            now: { Date() },
            stateProvider: { nil }
        )
        emitter.emit()
        XCTAssertTrue(transport.sent.isEmpty)
    }
}
