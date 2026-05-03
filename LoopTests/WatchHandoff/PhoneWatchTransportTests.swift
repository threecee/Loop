//
//  PhoneWatchTransportTests.swift
//  LoopTests
//
//  B.8.2 Issue #3: covers WCSessionPhoneWatchTransport.sendApplicationContext.
//  WCSession itself is Apple-final and not unit-testable in a paired sense, so
//  these tests focus on observable behavior: encoding correctness, the 8KB
//  safety-budget threshold, and the call-doesn't-throw contract.
//

import XCTest
import HealthKit
import LoopKit
import OmniBLE
import WatchConnectivity
@testable import Loop

final class PhoneWatchTransportTests: XCTestCase {

    // MARK: - 8KB safety-budget warning

    /// Builds a snapshot whose JSON-encoded form exceeds the 8KB threshold the
    /// production code logs against. The threshold is log-only and does NOT
    /// block delivery (per the B.8.2 spec) so the assertion is on the
    /// encoded-size invariant: if this test ever flips (encoded size <= 8KB),
    /// the warning code path stops being exercised in production and B.8.4
    /// loses its size signal.
    func testSendApplicationContextLogsWarningOnLargePayload() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let mgdl = HKUnit.milligramsPerDeciliter
        var glucoseSamples: [StoredGlucoseSample] = []
        glucoseSamples.reserveCapacity(120)
        for i in 0..<120 {
            let offset = TimeInterval(-i * 300)
            let date = now.addingTimeInterval(offset)
            let value = 100.0 + Double(i)
            let quantity = HKQuantity(unit: mgdl, doubleValue: value)
            let hkSample = HKQuantitySample(type: glucoseType, quantity: quantity, start: date, end: date)
            glucoseSamples.append(StoredGlucoseSample(sample: hkSample))
        }
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now,
            glucoseSamples: glucoseSamples,
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 50,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: now),
            activeOverride: nil
        )
        let message = PhoneWatchMessage.algorithmStateSnapshot(snapshot)

        // Sanity: the constructed payload must in fact exceed 8KB to exercise
        // the warning path. This is the load-bearing invariant — the test
        // wouldn't be meaningful without it.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try! encoder.encode(message)
        XCTAssertGreaterThan(encoded.count, 8 * 1024,
                             "Test fixture must exceed 8KB to exercise the warning path; got \(encoded.count) bytes")

        // The call itself must not throw. WCSession.default is unactivated in
        // the xctest harness, so updateApplicationContext throws internally —
        // production code's do/catch swallows it and logs via log.error. The
        // warning at >8KB is also logged before the throw, which is the
        // primary contract this test asserts is reachable.
        let transport = WCSessionPhoneWatchTransport(session: WCSession.default)
        transport.sendApplicationContext(message)
    }

    // MARK: - Small-payload happy path (sanity)

    func testSendApplicationContextSmallPayloadDoesNotThrow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now,
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 50,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: now),
            activeOverride: nil
        )
        let transport = WCSessionPhoneWatchTransport(session: WCSession.default)
        transport.sendApplicationContext(.algorithmStateSnapshot(snapshot))
    }
}
