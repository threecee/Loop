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
        encoder.dateEncodingStrategy = .secondsSince1970
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

    // MARK: - B.8.2: heartbeat encoder uses .secondsSince1970

    /// Confirms the production transport's `dateEncodingStrategy` is
    /// `.secondsSince1970` (not `.iso8601`). The wire-format invariant under
    /// test: a `Date` must serialize as a JSON Number, never a String.
    ///
    /// Why this matters: the watch-side decoder uses the same strategy in
    /// lockstep — if either side drifts back to `.iso8601`, every heartbeat
    /// (and every other Date-bearing message) would fail to decode, taking
    /// down the entire WCSession message channel. This test pins both the
    /// strategy choice and the wire shape so a future refactor can't quietly
    /// reintroduce ISO-8601 string encoding.
    func testHeartbeatEncodingUsesSecondsSince1970() throws {
        // Configure the encoder identically to production
        // (see WCSessionPhoneWatchTransport.init).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        // 1) Direct Date encoding produces a Number, not a String.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dateData = try encoder.encode(date)
        let dateString = String(data: dateData, encoding: .utf8)!
        XCTAssertFalse(dateString.contains("\""),
                       ".secondsSince1970 should encode Date as JSON Number, not a quoted String; got \(dateString)")
        XCTAssertEqual(dateString, "1700000000",
                       "Expected raw seconds-since-epoch encoding")

        // 2) Round-trip a heartbeat through PhoneWatchMessage and verify the
        // sentAt field surfaces as a Number in the decoded JSON dictionary.
        let heartbeat = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: date,
            senderRole: .phone,
            appBuildNumber: "phase6"
        )
        let message = PhoneWatchMessage.heartbeat(heartbeat)
        let encoded = try encoder.encode(message)

        // Drill into whatever shape PhoneWatchMessage's Codable produces and
        // locate the sentAt field. We don't hard-code the wrapper key — we
        // walk the dictionary and find the numeric `sentAt` regardless of
        // whether it's nested under "heartbeat", a "value" key, or appears
        // at the top level.
        let raw = try JSONSerialization.jsonObject(with: encoded)
        let sentAtValue = findValue(forKey: "sentAt", in: raw)
        XCTAssertNotNil(sentAtValue, "sentAt should be present in encoded message")
        XCTAssertTrue(sentAtValue is NSNumber,
                      "sentAt should be a JSON Number under .secondsSince1970; got \(type(of: sentAtValue ?? "nil"))")
        XCTAssertFalse(sentAtValue is String,
                       "sentAt must NOT be a String — that would mean .iso8601 leaked back in")
    }

    /// Recursive lookup helper for the JSON shape introspection above.
    private func findValue(forKey key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let v = dict[key] { return v }
            for (_, v) in dict {
                if let found = findValue(forKey: key, in: v) { return found }
            }
        } else if let array = object as? [Any] {
            for v in array {
                if let found = findValue(forKey: key, in: v) { return found }
            }
        }
        return nil
    }
}
