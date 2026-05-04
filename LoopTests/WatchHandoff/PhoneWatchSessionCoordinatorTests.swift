//
//  PhoneWatchSessionCoordinatorTests.swift
//  LoopTests
//
//  Coordinator state-transition tests, parallel to LoopWatchApp Watch AppTests'.
//

import XCTest
import OmniBLE
@testable import Loop

@MainActor
final class PhoneWatchSessionCoordinatorTests: XCTestCase {

    private var phoneTransport: MockPhoneWatchTransport!
    private var watchTransport: MockPhoneWatchTransport!
    private var phoneCoordinator: PhoneWatchSessionCoordinator!
    private var currentTime: Date!

    override func setUp() async throws {
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        phoneTransport = MockPhoneWatchTransport()
        watchTransport = MockPhoneWatchTransport()
        phoneTransport.peer = watchTransport
        watchTransport.peer = phoneTransport
        phoneCoordinator = PhoneWatchSessionCoordinator(
            role: .phone,
            transport: phoneTransport,
            appBuildNumber: "TEST",
            clock: { [unowned self] in self.currentTime }
        )
    }

    func testInitialStateNotConnected() {
        XCTAssertFalse(phoneCoordinator.isConnected)
    }

    func testSendHeartbeatUsesPhoneRole() {
        phoneCoordinator.sendHeartbeat()
        if case .heartbeat(let hb) = phoneTransport.sentMessages[0] {
            XCTAssertEqual(hb.senderRole, .phone)
        } else {
            XCTFail("expected heartbeat")
        }
    }

    func testReceiveHeartbeatUpdatesLastHeartbeatReceivedAt() async {
        let watchHB = PhoneWatchHeartbeat(
            protocolVersion: 1, sentAt: currentTime, senderRole: .watch, appBuildNumber: "WATCH"
        )
        phoneCoordinator.start()
        watchTransport.sendMessage(.heartbeat(watchHB), reply: nil, onError: { _ in })
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(phoneCoordinator.lastHeartbeatReceivedAt, currentTime)
        XCTAssertTrue(phoneCoordinator.isConnected)
        phoneCoordinator.stop()
    }

    func testIsConnectedFalseAfter90SecondsOfNoHeartbeat() async {
        let watchHB = PhoneWatchHeartbeat(
            protocolVersion: 1, sentAt: currentTime, senderRole: .watch, appBuildNumber: "WATCH"
        )
        phoneCoordinator.start()
        watchTransport.sendMessage(.heartbeat(watchHB), reply: nil, onError: { _ in })
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(phoneCoordinator.isConnected)
        currentTime = currentTime.addingTimeInterval(91)
        XCTAssertFalse(phoneCoordinator.isConnected)
        phoneCoordinator.stop()
    }

    func testRejectsHigherProtocolVersionHeartbeat() async {
        let futureHB = PhoneWatchHeartbeat(
            protocolVersion: 99, sentAt: currentTime, senderRole: .watch, appBuildNumber: "?"
        )
        phoneCoordinator.start()
        watchTransport.sendMessage(.heartbeat(futureHB), reply: nil, onError: { _ in })
        await Task.yield()
        await Task.yield()
        XCTAssertNil(phoneCoordinator.lastHeartbeatReceivedAt)
        phoneCoordinator.stop()
    }

    func testModeSwitchMessageHandledWithoutCrash() async {
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: currentTime, requestedBy: .watch,
            targetMode: .watchDriver, transitionId: UUID()
        )
        phoneCoordinator.start()
        watchTransport.sendMessage(.modeSwitch(ms), reply: nil, onError: { _ in })
        await Task.yield()
        phoneCoordinator.stop()
    }

    func testDebugEchoCompletesWithRoundTripTime() {
        phoneCoordinator.start()
        let expectation = expectation(description: "echo reply")
        phoneCoordinator.sendDebugEcho { result in
            switch result {
            case .success(let rtt):
                XCTAssertGreaterThanOrEqual(rtt, 0)
            case .failure(let err):
                XCTFail("unexpected error: \(err)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        phoneCoordinator.stop()
    }
}
