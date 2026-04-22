//
//  PhoneWatchTransportMock.swift
//  LoopTests
//
//  In-memory pair of transports for round-trip tests.
//

import Foundation
import OmniBLE
@testable import Loop

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
        reply?(.success(message))
    }

    func queueMessage(_ message: PhoneWatchMessage) {
        queuedMessages.append(message)
        peer?.onIncomingMessage?(message)
    }
}
