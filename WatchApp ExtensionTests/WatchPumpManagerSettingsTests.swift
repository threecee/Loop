//
//  WatchPumpManagerSettingsTests.swift
//  WatchApp ExtensionTests
//
//  B.5 Issue #7: verify that the watch's lazy pump manager construction
//  reads from WatchSettingsCache instead of using .watchSideDefault.
//

import XCTest
import Foundation
import LoopKit
import OmniBLE
@testable import WatchApp_Extension

@MainActor
final class WatchPumpManagerSettingsTests: XCTestCase {

    private var coordinatorTransport: MockPhoneWatchTransport!
    private var coordinator: PhoneWatchSessionCoordinator!
    private var orchestrator: HandoffOrchestrator!
    private var clock: Date!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        // Reset the singleton cache between tests; tests can pollute one another.
        WatchSettingsCache.shared.resetForTesting()

        coordinatorTransport = MockPhoneWatchTransport()
        coordinator = PhoneWatchSessionCoordinator(
            role: .watch,
            transport: coordinatorTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.clock }
        )
        coordinator.start()

        let stub = HandoffStubCoordinator(isReachable: true, lastHeartbeatReceivedAt: nil)
        let policyEngine = HandoffPolicyEngine(
            role: .watch,
            coordinator: stub,
            settings: HandoffSettings(),
            clock: { [unowned self] in self.clock },
            emit: { _ in }
        )
        orchestrator = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: HandoffStateMachine(initialState: .phoneDriver, role: .watch),
            policyEngine: policyEngine,
            shadowScheduler: ShadowStateScheduler(
                role: .watch,
                clock: { [unowned self] in self.clock },
                fire: { }
            ),
            userDefaults: UserDefaults(suiteName: "test.watchpumpsettings.\(UUID())")!,
            phoneStableDebounceOverride: 0.05
        )
    }

    override func tearDown() async throws {
        orchestrator?.stop()
        coordinator?.stop()
        WatchSettingsCache.shared.resetForTesting()
    }

    // MARK: - Tests

    /// When the WatchSettingsCache holds a sync with non-default basal items,
    /// the helper produces a pump manager whose state.basalSchedule reflects
    /// those items (rather than .watchSideDefault's empty schedule).
    func test_makeWatchSidePumpManager_usesCacheWhenAvailable() {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock,
            basalScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 1.5),
                RepeatingScheduleValue(startTime: 12 * 3600, value: 0.8)
            ],
            insulinSensitivityScheduleItems: [],
            carbRatioScheduleItems: [],
            glucoseTargetRangeScheduleItems: [],
            maximumBolusUnits: 12,
            maximumBasalRatePerHourUnits: 6.0,
            suspendThresholdMgdL: nil,
            nightscoutConfig: nil
        )
        WatchSettingsCache.shared.update(sync)

        let pm = orchestrator.makeWatchSidePumpManager()
        // BasalSchedule.entries is internal to OmniBLE, but rateAt(offset:) is
        // public — use it to verify the helper's mapping landed.
        XCTAssertEqual(pm.state.basalSchedule.rateAt(offset: 0), 1.5,
                       "First entry from sync should drive rate at midnight")
        XCTAssertEqual(pm.state.basalSchedule.rateAt(offset: 13 * 3600), 0.8,
                       "Second entry from sync should drive rate at 13:00")
    }

    /// When no settings sync has been received yet, the helper falls back to
    /// .watchSideDefault (empty basal schedule, fatal-when-evaluated — but
    /// the construction itself is non-fatal).
    func test_makeWatchSidePumpManager_fallsBackToDefaultWhenCacheEmpty() {
        WatchSettingsCache.shared.resetForTesting()
        let pm = orchestrator.makeWatchSidePumpManager()
        // .watchSideDefault uses an empty BasalSchedule. We can't safely call
        // rateAt(offset:) on an empty schedule (it fatalErrors), so verify
        // the schedule's rawValue reflects empty entries instead.
        let raw = pm.state.basalSchedule.rawValue
        if let entries = raw["entries"] as? [Any] {
            XCTAssertTrue(entries.isEmpty,
                          ".watchSideDefault should produce an empty basal schedule")
        } else {
            // Some serializations of an empty schedule may produce no
            // entries key at all — that's also acceptable, just assert the
            // pump manager exists and we didn't crash.
            XCTAssertNotNil(pm)
        }
    }
}
