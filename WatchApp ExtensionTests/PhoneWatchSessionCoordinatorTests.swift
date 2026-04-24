//
//  PhoneWatchSessionCoordinatorTests.swift
//  LoopWatchApp Watch AppTests
//
//  Coordinator state-transition tests using the in-memory paired transports.
//

import XCTest
import OmniBLE
@testable import WatchApp_Extension

@MainActor
final class PhoneWatchSessionCoordinatorTests: XCTestCase {

    private var phoneTransport: MockPhoneWatchTransport!
    private var watchTransport: MockPhoneWatchTransport!
    private var watchCoordinator: PhoneWatchSessionCoordinator!
    private var currentTime: Date!

    override func setUp() async throws {
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        phoneTransport = MockPhoneWatchTransport()
        watchTransport = MockPhoneWatchTransport()
        phoneTransport.peer = watchTransport
        watchTransport.peer = phoneTransport
        watchCoordinator = PhoneWatchSessionCoordinator(
            transport: watchTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.currentTime }
        )
    }

    func testInitialStateNotConnected() {
        XCTAssertFalse(watchCoordinator.isConnected)
        XCTAssertNil(watchCoordinator.lastHeartbeatReceivedAt)
    }

    func testSendHeartbeatDispatchesToPeer() {
        watchCoordinator.sendHeartbeat()
        XCTAssertEqual(watchTransport.sentMessages.count, 1)
        if case .heartbeat(let hb) = watchTransport.sentMessages[0] {
            XCTAssertEqual(hb.senderRole, .watch)
            XCTAssertEqual(hb.appBuildNumber, "TEST")
        } else {
            XCTFail("expected heartbeat message")
        }
    }

    func testReceiveHeartbeatUpdatesLastHeartbeatReceivedAt() async {
        let phoneHB = PhoneWatchHeartbeat(
            protocolVersion: 1, sentAt: currentTime, senderRole: .phone, appBuildNumber: "PHONE"
        )
        // Wire the coordinator's handler
        watchCoordinator.start()

        // Simulate phone sending to watch
        phoneTransport.sendMessage(.heartbeat(phoneHB), reply: nil, onError: { _ in })

        // Allow the @MainActor-hopped handler to run
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(watchCoordinator.lastHeartbeatReceivedAt, currentTime)
        XCTAssertTrue(watchCoordinator.isConnected)
        watchCoordinator.stop()
    }

    func testIsConnectedFalseAfter90SecondsOfNoHeartbeat() async {
        let phoneHB = PhoneWatchHeartbeat(
            protocolVersion: 1, sentAt: currentTime, senderRole: .phone, appBuildNumber: "PHONE"
        )
        watchCoordinator.start()
        phoneTransport.sendMessage(.heartbeat(phoneHB), reply: nil, onError: { _ in })
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(watchCoordinator.isConnected)

        // Advance clock 91 seconds.
        currentTime = currentTime.addingTimeInterval(91)

        XCTAssertFalse(watchCoordinator.isConnected)
        watchCoordinator.stop()
    }

    func testRejectsHigherProtocolVersionHeartbeat() async {
        let futureHB = PhoneWatchHeartbeat(
            protocolVersion: 99, sentAt: currentTime, senderRole: .phone, appBuildNumber: "?"
        )
        watchCoordinator.start()
        phoneTransport.sendMessage(.heartbeat(futureHB), reply: nil, onError: { _ in })
        await Task.yield()
        await Task.yield()
        XCTAssertNil(watchCoordinator.lastHeartbeatReceivedAt,
                     "higher-version heartbeat must not update state")
        watchCoordinator.stop()
    }

    func testModeSwitchMessageHandledWithoutCrash() async {
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: currentTime, requestedBy: .phone,
            targetMode: .watchDriver, transitionId: UUID()
        )
        watchCoordinator.start()
        // Just verify no crash on dispatch; log-only stub in B.2.c.
        phoneTransport.sendMessage(.modeSwitch(ms), reply: nil, onError: { _ in })
        await Task.yield()
        watchCoordinator.stop()
    }

    func testPairingHandoffMessageHandledWithoutCrash() async {
        let ph = PhoneWatchPairingHandoff(
            protocolVersion: 1, sentAt: currentTime, podId: "POD",
            pairingPayload: Data([0x01]), validUntil: currentTime.addingTimeInterval(60),
            transitionId: UUID()
        )
        watchCoordinator.start()
        phoneTransport.sendMessage(.pairingHandoff(ph), reply: nil, onError: { _ in })
        await Task.yield()
        watchCoordinator.stop()
    }
}
