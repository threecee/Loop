//
//  APNsTokenRegistrationTests.swift
//  WatchApp ExtensionTests
//
//  B.11.0 sim-only round-trip: a fake `didRegisterForRemoteNotifications`
//  callback persists the token to the local APNsTokenStore and emits an
//  `apnsTokenPublish` PhoneWatchMessage over the queued transport.
//

import XCTest
import OmniBLE
@testable import WatchApp_Extension

final class APNsTokenRegistrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var transport: FakeTransport!

    override func setUp() {
        super.setUp()
        let suite = "APNsTokenRegistrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        transport = FakeTransport()
    }

    /// On a simulated didRegisterForRemoteNotifications callback the
    /// helper persists a watch-slot APNsTokenPublication and queues an
    /// apnsTokenPublish PhoneWatchMessage with the same payload.
    func testWatchRegistrationPersistsAndPublishes() {
        let token = Data([0xab, 0xcd, 0xef, 0x12, 0x34])
        // Helper under test mirrors ExtensionDelegate.didRegisterForRemoteNotifications,
        // factored out for direct testing without a live WKExtension.
        WatchAPNsRegistration.handleDidRegister(
            deviceToken: token,
            transport: transport,
            store: APNsTokenStore(defaults: defaults),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        // Assert: persistence
        let stored = APNsTokenStore(defaults: defaults).load(role: .watch)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.token, token)
        XCTAssertEqual(stored?.role, .watch)
        XCTAssertEqual(stored?.protocolVersion, 7)
        // Assert: publication
        XCTAssertEqual(transport.queued.count, 1)
        guard case .apnsTokenPublish(let pub) = transport.queued.first else {
            XCTFail("Expected apnsTokenPublish message; got \(String(describing: transport.queued.first))")
            return
        }
        XCTAssertEqual(pub.token, token)
        XCTAssertEqual(pub.role, .watch)
    }
}

private final class FakeTransport: PhoneWatchTransportQueueing {
    var queued: [PhoneWatchMessage] = []
    func queueMessage(_ message: PhoneWatchMessage) {
        queued.append(message)
    }
}
