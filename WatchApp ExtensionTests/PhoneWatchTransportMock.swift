//
//  PhoneWatchTransportMock.swift
//  LoopWatchApp Watch AppTests
//
//  In-memory pair of transports for round-trip tests. Each mock holds a
//  reference to its peer; sending on one fires the onIncomingMessage of
//  the peer.
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
