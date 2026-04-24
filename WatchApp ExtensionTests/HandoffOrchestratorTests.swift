//
//  HandoffOrchestratorTests.swift
//  LoopWatchApp Watch AppTests
//

import XCTest
import Combine
import OmniBLE
@testable import WatchApp_Extension

@MainActor
final class HandoffOrchestratorTests: XCTestCase {

    private var coordinatorTransport: MockPhoneWatchTransport!
    private var coordinator: PhoneWatchSessionCoordinator!
    private var orchestrator: HandoffOrchestrator!
    private var clock: Date!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        coordinatorTransport = MockPhoneWatchTransport()
        coordinator = PhoneWatchSessionCoordinator(
            transport: coordinatorTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.clock }
        )
        // Wire the transport's onIncomingMessage so the coordinator can dispatch.
        coordinator.start()

        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        orchestrator = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .watch),
            policyEngine: HandoffPolicyEngine(
                coordinator: stub,
                settings: HandoffSettings(),
                clock: { [unowned self] in self.clock },
                emit: { _ in }
            ),
            shadowScheduler: ShadowStateScheduler(
                clock: { [unowned self] in self.clock },
                fire: { }
            ),
            userDefaults: UserDefaults(suiteName: "test.handoff.\(UUID())")!
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

    func testIncomingModeSwitchAdvancesStateMachine() {
        // Watch starts in phoneDriver; phone sends a mode switch declaring watch should drive.
        let id = UUID()
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: clock,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        orchestrator.handleIncoming(message: .modeSwitch(ms))
        XCTAssertTrue(orchestrator.handoffState.isTransitioning)
    }

    func testIncomingConfirmationCompletesHandoff() {
        // Step 1: get into handoffPending(phoneToWatch) with known id
        let id = UUID()
        let request = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: clock,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        orchestrator.handleIncoming(message: .modeSwitch(request))
        XCTAssertTrue(orchestrator.handoffState.isTransitioning)

        // Step 2: receive the confirmation
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
        // Force orchestrator into recovering state via state machine direct manipulation.
        orchestrator.injectStateMachine(HandoffStateMachine(
            initialState: .recovering(reason: .timeoutWaitingForConfirmation,
                                       lastKnownOwner: .phone),
            role: .watch))
        orchestrator.dismissRecovering()
        XCTAssertEqual(orchestrator.handoffState, .phoneDriver)
    }

    func testIncomingPairingHandoffCachesPayload() throws {
        // Build a real OmniBLEHandoffPayload and ship it via pairingHandoff.
        let raw: [String: Any] = ["address": UInt32(0x12345678)]
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: raw, format: .binary, options: 0)
        let payload = OmniBLEHandoffPayload(
            podSerial: "TESTPOD",
            serializedPodState: serialized,
            lastBolusSequence: 7,
            lastBasalScheduleId: nil,
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
}
