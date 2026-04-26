//
//  SettingsSyncEmissionTests.swift
//  LoopTests
//
//  B.3.a Phase 6 — iOS-side settings-sync emission tests.
//
//  Test 1: emitSettingsSync() with a wired provider produces a
//          PhoneWatchSettingsSync and queues it via the transport.
//
//  Test 3: entering .handoffPending(phoneToWatch) triggers settings sync
//          emission (trigger point 3).
//

import XCTest
import Combine
import LoopKit
import OmniBLE
@testable import Loop

@MainActor
final class SettingsSyncEmissionTests: XCTestCase {

    private var transport: MockPhoneWatchTransport!
    private var coordinator: PhoneWatchSessionCoordinator!
    private var orchestrator: HandoffOrchestrator!
    private var clock: Date!

    private let sampleSync = PhoneWatchSettingsSync(
        protocolVersion: PhoneWatchProtocol.currentVersion,
        sentAt: Date(timeIntervalSince1970: 1_700_000_000),
        basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
        insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
        carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
        glucoseTargetRangeScheduleItems: [
            RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
        ],
        maximumBolusUnits: 10.0,
        maximumBasalRatePerHourUnits: 4.0,
        suspendThresholdMgdL: 72.0,
        nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
            url: URL(string: "https://ns.example.com")!,
            apiSecret: "hunter2"
        )
    )

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        transport = MockPhoneWatchTransport()
        coordinator = PhoneWatchSessionCoordinator(
            transport: transport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.clock }
        )
        coordinator.start()
    }

    override func tearDown() async throws {
        orchestrator?.stop()
        coordinator?.stop()
    }

    private func makeOrchestrator(provideSync: Bool = true) -> HandoffOrchestrator {
        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        let orch = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .phone),
            policyEngine: HandoffPolicyEngine(
                coordinator: stub,
                settings: HandoffSettings(),
                clock: { [unowned self] in self.clock },
                emit: { _ in }
            ),
            shadowScheduler: ShadowStateScheduler(
                clock: { [unowned self] in self.clock },
                fire: {}
            ),
            userDefaults: UserDefaults(suiteName: "test.settingssync.\(UUID())")!,
            pumpManager: nil,
            settingsSyncProvider: provideSync ? { [weak self] in self?.sampleSync } : nil
        )
        return orch
    }

    // MARK: - Test 1: emitSettingsSync queues a .settingsSync message

    func testEmitSettingsSyncQueuesMessageWhenProviderIsWired() {
        orchestrator = makeOrchestrator(provideSync: true)

        let countBefore = transport.queuedMessages.count
        orchestrator.emitSettingsSync()

        let newMessages = transport.queuedMessages.dropFirst(countBefore)
        XCTAssertEqual(newMessages.count, 1,
                       "emitSettingsSync should queue exactly one message")

        guard case .settingsSync(let sent) = newMessages.first else {
            XCTFail("Expected a .settingsSync message; got \(String(describing: newMessages.first))")
            return
        }
        XCTAssertEqual(sent.maximumBolusUnits, 10.0)
        XCTAssertEqual(sent.nightscoutConfig?.apiSecret, "hunter2")
    }

    func testEmitSettingsSyncIsNoOpWhenProviderIsNil() {
        orchestrator = makeOrchestrator(provideSync: false)
        let countBefore = transport.queuedMessages.count
        orchestrator.emitSettingsSync()
        XCTAssertEqual(transport.queuedMessages.count, countBefore,
                       "emitSettingsSync must be no-op when settingsSyncProvider is nil")
    }

    // MARK: - Test 3: entering .handoffPending(phoneToWatch) triggers sync

    func testHandoffPendingPhoneToWatchTriggersSyncEmission() {
        orchestrator = makeOrchestrator(provideSync: true)
        orchestrator.start()

        // Clear any messages queued during start() (trigger point 1).
        transport.queuedMessages.removeAll()

        // Trigger a phone→watch handoff request which enters .handoffPending.
        orchestrator.userRequestHandoff(to: .watch)

        let syncs = transport.queuedMessages.filter {
            if case .settingsSync = $0 { return true }; return false
        }
        XCTAssertFalse(syncs.isEmpty,
                       "Entering .handoffPending(phoneToWatch) should trigger settings sync emission")
    }

    // MARK: - Test: notifySettingsChanged also triggers sync

    func testNotifySettingsChangedEmitsSync() {
        orchestrator = makeOrchestrator(provideSync: true)
        transport.queuedMessages.removeAll()

        orchestrator.notifySettingsChanged()

        let syncs = transport.queuedMessages.filter {
            if case .settingsSync = $0 { return true }; return false
        }
        XCTAssertEqual(syncs.count, 1,
                       "notifySettingsChanged should queue exactly one settings sync")
    }
}
