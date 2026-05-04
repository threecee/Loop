//
//  HandoffPolicyEngineTests.swift
//  LoopWatchApp Watch AppTests
//

import XCTest
import OmniBLE
@testable import WatchApp_Extension

@MainActor
final class HandoffPolicyEngineTests: XCTestCase {

    private var emittedEvents: [HandoffEvent] = []
    private var clock: Date!

    override func setUp() async throws {
        emittedEvents = []
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeEngine(mode: HandoffMode = .automatic,
                            stubbedReachable: Bool = true,
                            lastHeartbeat: Date? = nil) -> HandoffPolicyEngine {
        let stubCoordinator = HandoffStubCoordinator(
            isReachable: stubbedReachable,
            lastHeartbeatReceivedAt: lastHeartbeat
        )
        return HandoffPolicyEngine(
            role: .watch,
            coordinator: stubCoordinator,
            settings: HandoffSettings(mode: mode),
            clock: { [unowned self] in self.clock },
            emit: { [unowned self] in self.emittedEvents.append($0) }
        )
    }

    func testManualMode_NeverEmits() {
        let engine = makeEngine(mode: .manual, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-300))
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [])
    }

    func testAutomaticMode_HeartbeatAbsentLessThan60s_DoesNotEmit() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-30))
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [])
    }

    func testAutomaticMode_HeartbeatAbsent60s_EmitsTakeoverRequest() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-61))
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents.count, 1)
        if case .policyRequestedHandoff(target: .watch) = emittedEvents[0] {
            // OK
        } else {
            XCTFail("expected policyRequestedHandoff(.watch)")
        }
    }

    func testAutomaticMode_HeartbeatPresent_DoesNotEmit() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: true,
                                lastHeartbeat: clock.addingTimeInterval(-5))
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [])
    }

    func testManualWithAutoRevertMode_OnlyEmitsRevert() {
        // From watch's perspective, watch is currently watchDriver; phone
        // returns reachable for ≥60s → emit revert (.policyRequestedHandoff(.phone))
        let engine = makeEngine(mode: .manualWithAutoRevert, stubbedReachable: true,
                                lastHeartbeat: clock.addingTimeInterval(-5))
        engine.markCurrentOwner(.watch)
        engine.markPhoneStableSince(clock.addingTimeInterval(-65))
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents.count, 1)
        if case .policyRequestedHandoff(target: .phone) = emittedEvents[0] {
            // OK
        } else {
            XCTFail("expected revert event")
        }
    }

    func testManualWithAutoRevertMode_DoesNotTakeOver() {
        // From watch's perspective, currentOwner = .phone; mode .manualWithAutoRevert.
        // Should never emit takeover (only revert).
        let engine = makeEngine(mode: .manualWithAutoRevert, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-300))
        engine.markCurrentOwner(.phone)
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [])
    }

    func testStartTriggersPeriodicEvaluation() async {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-120))
        engine.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s (engine ticks at 1Hz)
        engine.stop()
        XCTAssertGreaterThanOrEqual(emittedEvents.count, 1)
    }

    func testStopHaltsEvaluation() async {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-120))
        engine.start()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        engine.stop()
        let countAfterStop = emittedEvents.count
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(emittedEvents.count, countAfterStop)
    }

    func testNoUserActivityRequirement_RecentActivityBlocksEmit() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-120))
        engine.markUserInteractedAt(clock.addingTimeInterval(-10))  // 10s ago, < 30s threshold
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [],
                       "recent user activity should suppress automatic trigger")
    }

    func testRebounceBlocksRapidRetriggers() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-120))
        engine.evaluateNow()
        engine.evaluateNow()  // Second call within rebounce window
        XCTAssertEqual(emittedEvents.count, 1, "rebounce should suppress duplicate triggers")
    }

    func testCachedPodStateAgeRequirement() {
        let engine = makeEngine(mode: .automatic, stubbedReachable: false,
                                lastHeartbeat: clock.addingTimeInterval(-120))
        engine.markCachedPodStateAge(clock.addingTimeInterval(-700))  // 11.7 min, > 10 min threshold
        engine.evaluateNow()
        XCTAssertEqual(emittedEvents, [],
                       "stale cached pod state should suppress automatic trigger")
    }
}

/// Minimal stub conforming to the interface HandoffPolicyEngine uses from
/// PhoneWatchSessionCoordinator. Production engine uses the real coordinator;
/// tests pass this stub.
@MainActor
final class HandoffStubCoordinator: HandoffPolicyCoordinatorObservable {
    var isReachable: Bool
    var lastHeartbeatReceivedAt: Date?

    init(isReachable: Bool, lastHeartbeatReceivedAt: Date?) {
        self.isReachable = isReachable
        self.lastHeartbeatReceivedAt = lastHeartbeatReceivedAt
    }
}
