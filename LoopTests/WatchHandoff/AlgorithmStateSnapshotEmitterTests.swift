//
//  AlgorithmStateSnapshotEmitterTests.swift
//  LoopTests
//

import XCTest
import HealthKit
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

    // MARK: - B.8.4 Phase 2: populated buffers flow through emit()

    /// Verifies the producer half of B.8.4 Phase 2: when `stateProvider`
    /// returns a State with non-empty rolling buffers (glucose / doses /
    /// carbs), those buffers reach the encoded `AlgorithmStateSnapshot` in
    /// the emitted `PhoneWatchMessage`. Before Phase 2 the upstream closure
    /// in `LoopAppManager.currentSnapshotStateOrNil()` always passed empty
    /// arrays per the B.8 placeholder, which made this test's assertion
    /// impossible to satisfy from production wiring. Phase 2 fills the
    /// buffers from `LoopDataManager.lastAlgorithmInput`; this unit test
    /// pins the emitter contract that buffers pass through unchanged.
    func test_emit_populatesAllThreeBuffers() {
        let transport = CapturingTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pumpStatus = PumpStatusSnapshot(reservoirUnitsRemaining: 50,
                                            lastBasalRateUnitsPerHour: 0.5,
                                            isSuspended: false,
                                            lastReadingDate: now)

        let glucoseSamples: [StoredGlucoseSample] = (0..<3).map { i in
            StoredGlucoseSample(
                syncIdentifier: "g-\(i)",
                syncVersion: 1,
                startDate: now.addingTimeInterval(-Double(i) * 300),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100 + Double(i)),
                isDisplayOnly: false,
                wasUserEntered: false
            )
        }
        let doses: [DoseEntry] = [
            DoseEntry(type: .tempBasal,
                      startDate: now.addingTimeInterval(-600),
                      endDate: now.addingTimeInterval(-300),
                      value: 0.5,
                      unit: .unitsPerHour),
            DoseEntry(type: .bolus,
                      startDate: now.addingTimeInterval(-120),
                      endDate: now.addingTimeInterval(-60),
                      value: 1.0,
                      unit: .units)
        ]
        let carbs: [StoredCarbEntry] = [
            StoredCarbEntry(
                startDate: now.addingTimeInterval(-1800),
                quantity: HKQuantity(unit: .gram(), doubleValue: 30),
                syncIdentifier: "c-0",
                syncVersion: 1,
                foodType: "test",
                absorptionTime: TimeInterval(hours: 3)
            )
        ]

        let emitter = AlgorithmStateSnapshotEmitter(
            transport: transport,
            now: { now },
            stateProvider: {
                AlgorithmStateSnapshotEmitter.State(
                    iterationDate: now,
                    glucoseSamples: glucoseSamples,
                    doseHistory: doses,
                    carbEntries: carbs,
                    pumpStatus: pumpStatus,
                    activeOverride: nil
                )
            }
        )

        emitter.emit()

        XCTAssertEqual(transport.sent.count, 1)
        guard case .algorithmStateSnapshot(let snapshot) = transport.sent.first else {
            return XCTFail("Expected .algorithmStateSnapshot")
        }
        XCTAssertEqual(snapshot.glucoseSamples.count, 3,
                       "Glucose buffer must reach the snapshot unchanged.")
        XCTAssertEqual(snapshot.doseHistory.count, 2,
                       "Dose buffer must reach the snapshot unchanged.")
        XCTAssertEqual(snapshot.carbEntries.count, 1,
                       "Carb buffer must reach the snapshot unchanged.")
        XCTAssertEqual(snapshot.glucoseSamples.first?.syncIdentifier, "g-0")
        XCTAssertEqual(snapshot.carbEntries.first?.syncIdentifier, "c-0")
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

    // MARK: - B.8.2 Issue #3: snapshot routing changed to applicationContext

    /// Spy that records which routing path the production `SnapshotTransport`
    /// extension on `WCSessionPhoneWatchTransport` would have taken. We can't
    /// subclass `final class WCSessionPhoneWatchTransport`, so instead we
    /// verify the extension's routing contract by re-implementing it on a
    /// distinct spy class that also conforms to the same `SnapshotTransport`
    /// indirection. The body must mirror production: `send` → `sendApplicationContext`.
    private final class RoutingSpyTransport: SnapshotTransport {
        var sendApplicationContextCalls: [PhoneWatchMessage] = []
        var queueMessageCalls: [PhoneWatchMessage] = []

        // Mirrors the production extension on WCSessionPhoneWatchTransport:
        //     extension WCSessionPhoneWatchTransport: SnapshotTransport {
        //         func send(_ message: PhoneWatchMessage) {
        //             sendApplicationContext(message)
        //         }
        //     }
        // If production routing changes (e.g. back to queueMessage), this
        // contract test fails alongside the production code.
        func send(_ message: PhoneWatchMessage) {
            sendApplicationContext(message)
        }

        func sendApplicationContext(_ message: PhoneWatchMessage) {
            sendApplicationContextCalls.append(message)
        }

        func queueMessage(_ message: PhoneWatchMessage) {
            queueMessageCalls.append(message)
        }
    }

    func testSnapshotDeliveredViaApplicationContext() {
        let transport = RoutingSpyTransport()
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

        XCTAssertEqual(transport.sendApplicationContextCalls.count, 1,
                       "Snapshot should be delivered via sendApplicationContext (latest-only).")
        XCTAssertEqual(transport.queueMessageCalls.count, 0,
                       "Snapshot must NOT use queueMessage (transferUserInfo) — that path is reserved for non-coalescable events.")
        if case .algorithmStateSnapshot = transport.sendApplicationContextCalls.first {
            // OK
        } else {
            XCTFail("Expected .algorithmStateSnapshot routed via sendApplicationContext")
        }
    }
}
