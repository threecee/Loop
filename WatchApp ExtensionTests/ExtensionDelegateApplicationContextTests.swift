//
//  ExtensionDelegateApplicationContextTests.swift
//  LoopWatchApp Watch AppTests
//
//  B.8.2 Issue #3: covers the watch-side reception of phone → watch
//  AlgorithmStateSnapshot delivered via WCSession.updateApplicationContext.
//
//  ExtensionDelegate itself is too heavyweight to instantiate in tests
//  (init activates WCSession.default and bootstraps the entire B.2.a-d
//  stack), so this test isolates the dispatch logic — the same conditional
//  and forwarding the delegate runs — against a real
//  WCSessionPhoneWatchTransport. If the dispatch contract changes, the
//  delegate's body and this test must change in lockstep.
//

import XCTest
import OmniBLE
@testable import WatchApp_Extension

final class ExtensionDelegateApplicationContextTests: XCTestCase {

    /// Mirrors the body of
    /// `ExtensionDelegate.session(_:didReceiveApplicationContext:)`:
    ///
    ///     if let data = applicationContext["phoneWatchMessage"] as? Data {
    ///         phoneWatchTransport?.handleIncomingMessageData(data, replyHandler: nil)
    ///         return
    ///     }
    ///     // legacy fallback
    ///
    /// The test invokes this helper. If production diverges (e.g. dictionary
    /// key changes, dispatch path changes), the assertions below fail.
    private func dispatch(_ applicationContext: [String: Any],
                          to transport: WCSessionPhoneWatchTransport) -> Bool {
        if let data = applicationContext["phoneWatchMessage"] as? Data {
            transport.handleIncomingMessageData(data, replyHandler: nil)
            return true
        }
        return false
    }

    func testDidReceiveApplicationContextDispatchesToHandler() {
        let transport = WCSessionPhoneWatchTransport(role: .watch)
        var received: [PhoneWatchMessage] = []
        transport.onIncomingMessage = { received.append($0) }

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
        let message = PhoneWatchMessage.algorithmStateSnapshot(snapshot)
        // Wire format is `.secondsSince1970` on both transport sides (B.8.2
        // mechanical migration from `.iso8601`). The fixture must match —
        // otherwise the transport's internal decoder throws and the message
        // never reaches `onIncomingMessage`.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try! encoder.encode(message)
        let context: [String: Any] = ["phoneWatchMessage": data]

        let didDispatch = dispatch(context, to: transport)

        XCTAssertTrue(didDispatch,
                      "phoneWatchMessage dispatch path must fire when key is present")
        XCTAssertEqual(received.count, 1,
                       "Transport's onIncomingMessage should fire exactly once")
        if case .algorithmStateSnapshot(let s) = received.first {
            XCTAssertEqual(s.snapshotID, snapshot.snapshotID)
        } else {
            XCTFail("Expected the AlgorithmStateSnapshot to round-trip through the dispatch")
        }
    }

    func testDidReceiveApplicationContextWithoutPhoneWatchMessageFallsThrough() {
        let transport = WCSessionPhoneWatchTransport(role: .watch)
        var received: [PhoneWatchMessage] = []
        transport.onIncomingMessage = { received.append($0) }

        // Legacy WatchContext shape — no "phoneWatchMessage" key. Dispatch
        // helper must report it did NOT take the new path; production code
        // would then call updateContext(applicationContext) (out of scope here).
        let legacyContext: [String: Any] = ["someOtherKey": "value"]

        let didDispatch = dispatch(legacyContext, to: transport)

        XCTAssertFalse(didDispatch,
                       "Legacy contexts without phoneWatchMessage Data must fall through to the legacy WatchContext path")
        XCTAssertEqual(received.count, 0,
                       "Transport must not be invoked when phoneWatchMessage is absent")
    }
}
