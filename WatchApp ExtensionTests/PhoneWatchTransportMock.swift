//
//  PhoneWatchTransportMock.swift
//  WatchApp ExtensionTests
//
//  Test helpers for the watch-side test target. Phase 6 (B.10) deduplicated
//  the iOS↔watch handoff test suites, deleting the watch-side copy of this
//  helper. `WatchPumpManagerSettingsTests` (which is watch-app-specific and
//  therefore retained on the watch side) still depends on
//  `MockPhoneWatchTransport` and `HandoffStubCoordinator`, so we re-add a
//  minimal pair of helpers here. The LoopTests target keeps its own copy.
//

import Foundation
import OmniBLE
@testable import WatchApp_Extension

final class MockPhoneWatchTransport: PhoneWatchTransport {
    weak var peer: MockPhoneWatchTransport?
    var onIncomingMessage: ((PhoneWatchMessage) -> Void)?
    var isReachable: Bool = true

    var sentMessages: [PhoneWatchMessage] = []
    var queuedMessages: [PhoneWatchMessage] = []

    func sendMessage(_ message: PhoneWatchMessage,
                     reply: ((Result<PhoneWatchMessage, Error>) -> Void)?,
                     onError: ((Error) -> Void)?) {
        sentMessages.append(message)
        guard isReachable, let peer = peer else {
            onError?(PhoneWatchTransportError.counterpartNotReachable)
            return
        }
        peer.onIncomingMessage?(message)
        // Default reply: echo back the same message.
        reply?(.success(message))
    }

    func queueMessage(_ message: PhoneWatchMessage) {
        queuedMessages.append(message)
        peer?.onIncomingMessage?(message)
    }
}

final class HandoffStubCoordinator: HandoffPolicyCoordinatorObservable {
    var isReachable: Bool
    var lastHeartbeatReceivedAt: Date?

    init(isReachable: Bool, lastHeartbeatReceivedAt: Date?) {
        self.isReachable = isReachable
        self.lastHeartbeatReceivedAt = lastHeartbeatReceivedAt
    }
}
