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

    // B.5 Issue #4 carryover: each direct HandoffStateMachine construction
    // gets a fresh, isolated UserDefaults suite so HandoffStatePersistence
    // (state.didSet -> save) from a prior test doesn't leak into the next
    // test's machine init via App Group UserDefaults.
    private var isolatedSuiteNames: [String] = []

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "B5_SettingsSyncEmissionTests_\(UUID().uuidString)"
        isolatedSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

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
        // B.5 Issue #4 carryover: clean up isolated UserDefaults suites.
        for suiteName in isolatedSuiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        isolatedSuiteNames.removeAll()
    }

    private func makeOrchestrator(
        provideSync: Bool = true,
        providedSyncOverride: PhoneWatchSettingsSync? = nil
    ) -> HandoffOrchestrator {
        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        let orch = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .phone,
                                              appGroupDefaults: isolatedDefaults()),
            policyEngine: HandoffPolicyEngine(
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
            userDefaults: UserDefaults(suiteName: "test.settingssync.\(UUID())")!,
            pumpManager: nil,
            settingsSyncProvider: provideSync
                ? { [weak self] in providedSyncOverride ?? self?.sampleSync }
                : nil
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

    // MARK: - B.5.2 Issue #3: timeZone field passthrough

    /// `LoopAppManager.makeWatchSettingsSync()` is the production builder of
    /// the sync payload — it now populates `timeZone` from `TimeZone.current`.
    /// The orchestrator-level emit tests use a sample sync directly, so to
    /// assert the field is wired in, we construct a sync mirroring production
    /// and verify the wire round-trip still carries the identifier.
    func testOutboundSyncIncludesTimeZoneFromCurrent() {
        // Build a sync payload exactly as LoopAppManager would: timeZone =
        // TimeZone.current.identifier at construction time.
        let phoneZoneIdentifier = TimeZone.current.identifier
        let syncWithZone = PhoneWatchSettingsSync(
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
            nightscoutConfig: nil,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true,
            timeZone: phoneZoneIdentifier
        )
        orchestrator = makeOrchestrator(provideSync: true, providedSyncOverride: syncWithZone)

        let countBefore = transport.queuedMessages.count
        orchestrator.emitSettingsSync()

        let newMessages = transport.queuedMessages.dropFirst(countBefore)
        guard case let .settingsSync(received) = newMessages.first else {
            return XCTFail("expected settingsSync message")
        }
        XCTAssertEqual(received.timeZone, phoneZoneIdentifier,
                       "Outbound sync must carry the phone's TimeZone.current identifier")
    }

    /// B.5.2 Issue #3b: posting `.NSSystemTimeZoneDidChange` synthetically
    /// triggers a fresh sync emission. The closure-based observer installed
    /// in `init(...)` calls `notifySettingsChanged()` → `emitSettingsSync()`.
    func testSystemTimeZoneDidChangeNotificationTriggersFreshEmission() {
        orchestrator = makeOrchestrator(provideSync: true)
        // Drain any messages queued during construction.
        transport.queuedMessages.removeAll()

        NotificationCenter.default.post(
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )

        // The closure observer is registered on `.main`; we're already on
        // @MainActor so the post is dispatched synchronously into the queue.
        // Spin one runloop tick to let it drain.
        let exp = expectation(description: "drain main runloop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let syncs = transport.queuedMessages.filter {
            if case .settingsSync = $0 { return true }; return false
        }
        XCTAssertEqual(syncs.count, 1,
                       "NSSystemTimeZoneDidChange should trigger exactly one fresh sync emission")
    }

    // MARK: - B.4 Issue #3: automaticDosing field passthrough

    /// emitSettingsSync builds a sync that includes the automaticDosing flags
    /// from the provider closure, so the watch receives them.
    func testEmitSettingsSyncIncludesAutomaticDosingFlags() {
        let syncWithFlags = PhoneWatchSettingsSync(
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
            nightscoutConfig: nil,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true
        )
        orchestrator = makeOrchestrator(provideSync: true, providedSyncOverride: syncWithFlags)

        let countBefore = transport.queuedMessages.count
        orchestrator.emitSettingsSync()

        let newMessages = transport.queuedMessages.dropFirst(countBefore)
        XCTAssertEqual(newMessages.count, 1)
        guard case let .settingsSync(received) = newMessages.first else {
            return XCTFail("expected settingsSync message")
        }
        XCTAssertEqual(received.automaticDosingEnabled, true)
        XCTAssertEqual(received.isAutomaticDosingAllowed, true)
        XCTAssertEqual(received.protocolVersion, PhoneWatchProtocol.currentVersion)
    }
}
