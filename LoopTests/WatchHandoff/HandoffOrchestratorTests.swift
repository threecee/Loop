//
//  HandoffOrchestratorTests.swift
//  LoopTests
//

import XCTest
import Combine
import OmniBLE
@testable import Loop

@MainActor
final class HandoffOrchestratorTests: XCTestCase {

    private var coordinatorTransport: MockPhoneWatchTransport!
    private var coordinator: PhoneWatchSessionCoordinator!
    private var orchestrator: HandoffOrchestrator!
    private var policyEngine: HandoffPolicyEngine!  // B.4 Issue #2: held for inspection
    private var clock: Date!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        coordinatorTransport = MockPhoneWatchTransport()
        coordinator = PhoneWatchSessionCoordinator(
            transport: coordinatorTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.clock }
        )
        coordinator.start()

        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        policyEngine = HandoffPolicyEngine(
            coordinator: stub,
            settings: HandoffSettings(),
            clock: { [unowned self] in self.clock },
            emit: { _ in }
        )
        orchestrator = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .phone),
            policyEngine: policyEngine,
            shadowScheduler: ShadowStateScheduler(
                clock: { [unowned self] in self.clock },
                fire: { }
            ),
            userDefaults: UserDefaults(suiteName: "test.handoff.\(UUID())")!,
            pumpManager: nil,
            phoneStableDebounceOverride: 0.05    // 50ms for tests
        )
    }

    override func tearDown() async throws {
        orchestrator?.stop()
        coordinator?.stop()
    }

    func testInitialStateIsPhoneDriver() {
        XCTAssertEqual(orchestrator.handoffState, .phoneDriver)
    }

    func testUserRequestHandoffToWatchTransitionsState() {
        orchestrator.userRequestHandoff(to: .watch)
        XCTAssertTrue(orchestrator.handoffState.isTransitioning)
    }

    func testIncomingModeSwitchSelfCompletesToWatchDriver() {
        // Was: testIncomingModeSwitchAdvancesStateMachine (asserted intermediate
        //   .handoffPending state). After B.2.e Phase 1 the receiver self-completes
        //   in one event, so the state machine lands on .watchDriver immediately.
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: UUID()
        )
        orchestrator.handleIncoming(message: .modeSwitch(ms))
        if case .watchDriver = orchestrator.handoffState {} else {
            XCTFail("Expected .watchDriver after receiver self-completes; got \(orchestrator.handoffState)")
        }
    }

    func testIncomingConfirmationCompletesHandoff() {
        // After B.2.e Phase 1: the first modeSwitch self-completes the receiver to
        // .watchDriver; a second modeSwitch with the same transitionId is a no-op
        // (default case). Final state is still .watchDriver.
        let id = UUID()
        let request = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: clock,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        orchestrator.handleIncoming(message: .modeSwitch(request))
        XCTAssertEqual(orchestrator.handoffState, .watchDriver)

        let confirm = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: clock,
            requestedBy: .phone, targetMode: .watchDriver, transitionId: id)
        orchestrator.handleIncoming(message: .modeSwitch(confirm))
        XCTAssertEqual(orchestrator.handoffState, .watchDriver)
    }

    func testUpdateSettingsPersistsToUserDefaults() {
        let suiteName = "test.handoff-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        orchestrator.userDefaults = defaults
        let newSettings = HandoffSettings(mode: .automatic)
        orchestrator.updateSettings(newSettings)
        let loaded = HandoffSettings.load(from: defaults)
        XCTAssertEqual(loaded.mode, .automatic)
    }

    func testDismissRecoveringReturnsToLastKnownOwner() {
        orchestrator.injectStateMachine(HandoffStateMachine(
            initialState: .recovering(reason: .timeoutWaitingForConfirmation,
                                       lastKnownOwner: .phone),
            role: .phone))
        orchestrator.dismissRecovering()
        XCTAssertEqual(orchestrator.handoffState, .phoneDriver)
    }

    func testIncomingPairingHandoffCachesPayload() throws {
        let raw: [String: Any] = ["address": UInt32(0x12345678)]
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: raw, format: .binary, options: 0)
        let payload = OmniBLEHandoffPayload(
            podSerial: "TESTPOD",
            serializedPodState: serialized,
            lastBolusSequence: 7,
            lastBasalScheduleId: nil,
            validUntil: Date.distantFuture,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let payloadData = try JSONEncoder().encode(payload)
        let ph = PhoneWatchPairingHandoff(
            protocolVersion: 1, sentAt: clock,
            podId: "TESTPOD", pairingPayload: payloadData,
            validUntil: clock.addingTimeInterval(60),
            transitionId: UUID())

        orchestrator.handleIncoming(message: .pairingHandoff(ph))
        XCTAssertNotNil(orchestrator.cachedPayload)
        XCTAssertEqual(orchestrator.cachedPayload?.podSerial, "TESTPOD")
    }

    // MARK: - B.4 Issue #2: policy-engine markX wiring

    func test_start_seedsCurrentOwnerToPhone() {
        orchestrator.start()
        XCTAssertEqual(policyEngine.debugCurrentOwner, .phone)
    }

    func test_userRequestHandoff_callsMarkUserInteractedAt() {
        let before = Date()
        orchestrator.userRequestHandoff(to: .watch)
        let recorded = policyEngine.debugLastUserInteractionAt
        XCTAssertNotNil(recorded)
        XCTAssertGreaterThanOrEqual(recorded!, before)
    }

    func test_notifyUI_marksCurrentOwnerOnTransitionToWatchDriver() {
        // Drive the state machine to .watchDriver via a self-completing
        // incoming modeSwitch (matches existing tests' pattern).
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: UUID()
        )
        orchestrator.handleIncoming(message: .modeSwitch(ms))
        XCTAssertEqual(orchestrator.handoffState, .watchDriver)
        XCTAssertEqual(policyEngine.debugCurrentOwner, .watch)
    }

    func test_reachabilityFlipOn_marksStableAfterDebounce() async throws {
        // The coordinator starts with isCounterpartReachable=false. Subscribing
        // in start() therefore emits an initial false (handler clears stable-since).
        orchestrator.start()
        await Task.yield()
        XCTAssertNil(policyEngine.debugPhoneStableReachableSince)

        // Drive a flip-ON by feeding an inbound heartbeat through the transport;
        // the coordinator updates isCounterpartReachable = true.
        let inboundHB = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            senderRole: .watch,
            appBuildNumber: "TEST"
        )
        let before = Date()
        coordinatorTransport.onIncomingMessage?(.heartbeat(inboundHB))
        // Allow main-actor hop + the 50ms debounce + slack.
        try await Task.sleep(nanoseconds: 300_000_000)
        let recorded = policyEngine.debugPhoneStableReachableSince
        XCTAssertNotNil(recorded, "expected markPhoneStableSince to fire after debounce")
        if let recorded {
            XCTAssertGreaterThanOrEqual(recorded, before)
        }
    }
}
