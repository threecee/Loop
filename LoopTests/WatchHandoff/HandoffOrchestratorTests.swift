//
//  HandoffOrchestratorTests.swift
//  LoopTests
//

import XCTest
import Combine
import LoopKit
import OmniBLE
@testable import Loop

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
        let suiteName = "B5_HandoffOrchestratorTests_\(UUID().uuidString)"
        isolatedSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        coordinatorTransport = MockPhoneWatchTransport()
        coordinator = PhoneWatchSessionCoordinator(
            role: .phone,
            transport: coordinatorTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.clock }
        )
        coordinator.start()

        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        policyEngine = HandoffPolicyEngine(
            role: .phone,
            coordinator: stub,
            settings: HandoffSettings(),
            clock: { [unowned self] in self.clock },
            emit: { _ in }
        )
        orchestrator = HandoffOrchestrator(
            role: .phone,
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .phone,
                                              appGroupDefaults: isolatedDefaults()),
            policyEngine: policyEngine,
            shadowScheduler: ShadowStateScheduler(
                role: .phone,
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
            role: .phone,
            appGroupDefaults: isolatedDefaults()))
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
        XCTAssertEqual(policyEngine.currentOwnerForTesting, .watch)
    }

    // MARK: - B.5 Issue #1: command-gate effect wiring

    /// .stopIssuingPodCommands effect sets ownership.commandsAllowed = false.
    func test_executeStopIssuingPodCommands_setsCommandsAllowedFalse() {
        XCTAssertTrue(orchestrator.ownership.commandsAllowed)  // sanity: starts true
        orchestrator.execute([.stopIssuingPodCommands])
        XCTAssertFalse(orchestrator.ownership.commandsAllowed)
    }

    /// .resumeIssuingPodCommands effect sets ownership.commandsAllowed = true.
    func test_executeResumeIssuingPodCommands_setsCommandsAllowedTrue() {
        orchestrator.ownership.commandsAllowed = false  // start in suppressed state
        orchestrator.execute([.resumeIssuingPodCommands])
        XCTAssertTrue(orchestrator.ownership.commandsAllowed)
    }

    // MARK: - B.8.2 Issue #4: phone-side settings-sync dedup

    /// Helper for the dedup tests below. Builds a fresh orchestrator wired
    /// to the test's `coordinator`/`coordinatorTransport` and a mutable
    /// `currentSync` reference so a test can change the payload between
    /// notify calls.
    private func makeOrchestratorForDedup(
        currentSync: @escaping () -> PhoneWatchSettingsSync?
    ) -> HandoffOrchestrator {
        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        return HandoffOrchestrator(
            role: .phone,
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .phone,
                                              appGroupDefaults: isolatedDefaults()),
            policyEngine: HandoffPolicyEngine(
                role: .phone,
                coordinator: stub,
                settings: HandoffSettings(),
                clock: { [unowned self] in self.clock },
                emit: { _ in }
            ),
            shadowScheduler: ShadowStateScheduler(
                role: .phone,
                clock: { [unowned self] in self.clock },
                fire: {}
            ),
            userDefaults: UserDefaults(suiteName: "test.handoff-dedup.\(UUID())")!,
            pumpManager: nil,
            settingsSyncProvider: currentSync,
            phoneStableDebounceOverride: 0.05
        )
    }

    private static func makeFixtureSync(maximumBolus: Double = 10.0) -> PhoneWatchSettingsSync {
        PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: maximumBolus,
            maximumBasalRatePerHourUnits: 4.0,
            suspendThresholdMgdL: 72.0,
            nightscoutConfig: nil
        )
    }

    private func settingsSyncCount(in transport: MockPhoneWatchTransport) -> Int {
        transport.queuedMessages.filter {
            if case .settingsSync = $0 { return true }; return false
        }.count
    }

    /// Phone-side dedup: two consecutive notifySettingsChanged() calls with
    /// the same payload should result in only one queued .settingsSync. A
    /// payload change after that should send again.
    func testEmitSettingsSyncDeduplicatesIdenticalPayload() {
        // Replace the default orchestrator with one wired to a mutable sync.
        orchestrator?.stop()
        var currentSync: PhoneWatchSettingsSync? = Self.makeFixtureSync()
        orchestrator = makeOrchestratorForDedup(currentSync: { currentSync })

        // Drain anything queued during construction (no start() called here).
        coordinatorTransport.queuedMessages.removeAll()

        orchestrator.notifySettingsChanged()
        XCTAssertEqual(settingsSyncCount(in: coordinatorTransport), 1,
                       "First emission should send")

        orchestrator.notifySettingsChanged()
        XCTAssertEqual(settingsSyncCount(in: coordinatorTransport), 1,
                       "Identical payload should not re-send")

        currentSync = Self.makeFixtureSync(maximumBolus: 7.5)
        orchestrator.notifySettingsChanged()
        XCTAssertEqual(settingsSyncCount(in: coordinatorTransport), 2,
                       "Different payload should send")
    }

    /// stop() clears the lastEmittedSync cache so a fresh start emits at
    /// least once even if the payload is byte-identical to the previous run.
    func testStopClearsLastEmittedSync() {
        orchestrator?.stop()
        let fixedSync = Self.makeFixtureSync()
        orchestrator = makeOrchestratorForDedup(currentSync: { fixedSync })

        coordinatorTransport.queuedMessages.removeAll()

        orchestrator.notifySettingsChanged()
        XCTAssertEqual(settingsSyncCount(in: coordinatorTransport), 1)

        orchestrator.stop()
        orchestrator.start()
        // start() schedules an emit on a Task; the test stays on @MainActor,
        // so spinning one runloop tick lets that Task run before we count.
        let exp = expectation(description: "drain main runloop after start")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // After stop/start, lastEmittedSync was cleared, so the first emit
        // (from start() trigger point 1) should re-send.
        XCTAssertGreaterThanOrEqual(settingsSyncCount(in: coordinatorTransport), 2,
                       "After stop/start cycle, identical payload should re-emit")
    }

    func test_reachabilityFlipOn_marksStableAfterDebounce() async throws {
        // The coordinator starts with isCounterpartReachable=false. Subscribing
        // in start() therefore emits an initial false (handler clears stable-since).
        orchestrator.start()
        await Task.yield()
        XCTAssertNil(policyEngine.phoneStableReachableSinceForTesting)

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
        let recorded = policyEngine.phoneStableReachableSinceForTesting
        XCTAssertNotNil(recorded, "expected markPhoneStableSince to fire after debounce")
        if let recorded {
            XCTAssertGreaterThanOrEqual(recorded, before)
        }
    }
}
