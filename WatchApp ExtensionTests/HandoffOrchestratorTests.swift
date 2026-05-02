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
    private var policyEngine: HandoffPolicyEngine!  // B.4 Issue #2: held for inspection
    private var clock: Date!

    // B.5 Issue #4 carryover: each direct HandoffStateMachine construction in
    // these tests gets a fresh, isolated UserDefaults suite so persisted state
    // (HandoffStatePersistence.save in state.didSet) from a prior test doesn't
    // leak into the next test's machine init via App Group UserDefaults.
    private var isolatedSuiteNames: [String] = []

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "B5_WatchHandoffOrchestratorTests_\(UUID().uuidString)"
        isolatedSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

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
        policyEngine = HandoffPolicyEngine(
            coordinator: stub,
            settings: HandoffSettings(),
            clock: { [unowned self] in self.clock },
            emit: { _ in }
        )
        orchestrator = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .watch,
                                              appGroupDefaults: isolatedDefaults()),
            policyEngine: policyEngine,
            shadowScheduler: ShadowStateScheduler(
                clock: { [unowned self] in self.clock },
                fire: { }
            ),
            userDefaults: UserDefaults(suiteName: "test.handoff.\(UUID())")!,
            phoneStableDebounceOverride: 0.05    // 50ms for tests
        )
    }

    override func tearDown() async throws {
        orchestrator?.stop()
        coordinator?.stop()
        // B.5 Issue #4 carryover: clean up isolated UserDefaults suites we
        // created so we don't leave stray entries in ~/Library/Preferences.
        for suiteName in isolatedSuiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        isolatedSuiteNames.removeAll()
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

        // Step 2: receive the confirmation (now a no-op since already in .watchDriver)
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
            role: .watch,
            appGroupDefaults: isolatedDefaults()))
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
        XCTAssertEqual(policyEngine.currentOwnerForTesting, .phone)
    }

    func test_userRequestHandoff_callsMarkUserInteractedAt() {
        let before = Date()
        orchestrator.userRequestHandoff(to: .watch)
        let recorded = policyEngine.lastUserInteractionAtForTesting
        XCTAssertNotNil(recorded)
        XCTAssertGreaterThanOrEqual(recorded!, before)
    }

    func test_notifyUI_marksCurrentOwnerOnTransitionToWatchDriver() {
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: UUID()
        )
        orchestrator.handleIncoming(message: .modeSwitch(ms))
        XCTAssertEqual(orchestrator.handoffState, .watchDriver)
        XCTAssertEqual(policyEngine.currentOwnerForTesting, .watch)
    }

    func test_reachabilityFlipOn_marksStableAfterDebounce() async throws {
        orchestrator.start()
        await Task.yield()
        XCTAssertNil(policyEngine.phoneStableReachableSinceForTesting)

        let inboundHB = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            senderRole: .phone,
            appBuildNumber: "TEST"
        )
        let before = Date()
        coordinatorTransport.onIncomingMessage?(.heartbeat(inboundHB))
        try await Task.sleep(nanoseconds: 300_000_000)
        let recorded = policyEngine.phoneStableReachableSinceForTesting
        XCTAssertNotNil(recorded, "expected markPhoneStableSince to fire after debounce")
        if let recorded {
            XCTAssertGreaterThanOrEqual(recorded, before)
        }
    }

    // MARK: - B.5 Issue #1: command-gate effect wiring (watch side)

    /// .stopIssuingPodCommands effect sets ownership.commandsAllowed = false.
    func test_executeStopIssuingPodCommands_setsCommandsAllowedFalse() {
        XCTAssertTrue(orchestrator.ownership.commandsAllowed)  // sanity: starts true
        orchestrator.execute([.stopIssuingPodCommands])
        XCTAssertFalse(orchestrator.ownership.commandsAllowed)
    }

    /// .resumeIssuingPodCommands effect sets ownership.commandsAllowed = true.
    func test_executeResumeIssuingPodCommands_setsCommandsAllowedTrue() {
        orchestrator.ownership.commandsAllowed = false
        orchestrator.execute([.resumeIssuingPodCommands])
        XCTAssertTrue(orchestrator.ownership.commandsAllowed)
    }

    // MARK: - B.5 Issue #5: split-brain detection (watch side)

    /// Watch silently demotes when phone heartbeat claims phone is owner
    /// while watch thinks watch is owner. Phone-wins arbitration.
    func test_heartbeat_splitBrain_watchDemotesItself() async {
        // Drive the watch to .watchDriver via a self-completing modeSwitch
        // (matches the established test pattern).
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: UUID()
        )
        orchestrator.handleIncoming(message: .modeSwitch(ms))
        XCTAssertEqual(orchestrator.handoffState, .watchDriver)
        XCTAssertEqual(orchestrator.handoffState.currentOwner, .watch)

        // Publish singleton so the coordinator's split-brain handler can find it.
        let savedShared = HandoffOrchestrator.shared
        HandoffOrchestrator.shared = orchestrator
        defer { HandoffOrchestrator.shared = savedShared }

        // Inject a phone heartbeat claiming the phone is owner — split-brain.
        let inboundHB = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            senderRole: .phone,
            appBuildNumber: "TEST",
            claimedOwner: .phone   // B.5 #5: phone claims phone
        )
        coordinatorTransport.onIncomingMessage?(.heartbeat(inboundHB))
        // Allow the @MainActor hop in the coordinator's incoming-dispatch.
        await Task.yield()
        await Task.yield()

        // Watch demoted: commands gated off + state machine reverted toward
        // phone (a userRequestHandoff(.phone) was emitted, so the state
        // should no longer be .watchDriver).
        XCTAssertFalse(orchestrator.ownership.commandsAllowed,
                       "watch should silently disable commands on split-brain")
        XCTAssertNotEqual(orchestrator.handoffState, .watchDriver,
                          "watch should leave .watchDriver on split-brain demotion")
    }

    func test_handleIncomingPairingHandoff_marksCachedPodStateAge() throws {
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

        let before = Date()
        orchestrator.handleIncoming(message: .pairingHandoff(ph))
        let recorded = policyEngine.cachedPodStateAtForTesting
        XCTAssertNotNil(recorded)
        if let recorded {
            XCTAssertGreaterThanOrEqual(recorded, before)
        }
    }
}
