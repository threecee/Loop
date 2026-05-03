//
//  PhoneWatchTransport.swift
//  Loop (iOS)
//
//  WCSession-backed transport for PhoneWatchMessage on the iOS side.
//  Mirrors WatchApp Extension's PhoneWatchTransport.
//
//  B.2.c.1: This transport NO LONGER conforms to WCSessionDelegate.
//  WatchDataManager owns the WCSession.default delegate role and forwards
//  incoming `messageData` and `phoneWatchMessage` userInfo to this transport
//  via handleIncomingMessageData(_:replyHandler:).
//

import Foundation
import os.log
import OmniBLE
import WatchConnectivity

public protocol PhoneWatchTransport: AnyObject {
    var isReachable: Bool { get }
    func sendMessage(_ message: PhoneWatchMessage,
                     reply: ((Result<PhoneWatchMessage, Error>) -> Void)?,
                     onError: ((Error) -> Void)?)
    func queueMessage(_ message: PhoneWatchMessage)
    var onIncomingMessage: ((PhoneWatchMessage) -> Void)? { get set }
}

public final class WCSessionPhoneWatchTransport: PhoneWatchTransport {
    public var onIncomingMessage: ((PhoneWatchMessage) -> Void)?

    private let session: WCSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let log = OSLog(category: "WCSessionPhoneWatchTransport")

    public var isReachable: Bool { session.isReachable }

    public init(session: WCSession = .default) {
        self.session = session
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        // No delegate assignment, no activate(). WatchDataManager owns both.
    }

    public func sendMessage(_ message: PhoneWatchMessage,
                            reply: ((Result<PhoneWatchMessage, Error>) -> Void)?,
                            onError: ((Error) -> Void)?) {
        guard session.isReachable else {
            onError?(PhoneWatchTransportError.counterpartNotReachable)
            return
        }
        do {
            let payload = try encoder.encode(message)
            session.sendMessageData(payload) { replyData in
                guard let reply = reply else { return }
                do {
                    let decoded = try self.decoder.decode(PhoneWatchMessage.self, from: replyData)
                    reply(.success(decoded))
                } catch {
                    reply(.failure(error))
                }
            } errorHandler: { err in
                onError?(err)
            }
        } catch {
            onError?(error)
        }
    }

    public func queueMessage(_ message: PhoneWatchMessage) {
        do {
            let payload = try encoder.encode(message)
            if session.isReachable {
                // Counterpart is foregrounded/reachable — use real-time delivery.
                // transferUserInfo is for background-deferred delivery and is
                // silently undelivered in iOS Simulator while both apps are
                // foregrounded, so handoff messages would never arrive.
                // sendMessageData with a no-op reply handler delivers immediately.
                session.sendMessageData(payload, replyHandler: { _ in
                    // No-op: this is a fire-and-forget message; ack data ignored.
                }) { [weak self] _ in
                    // Send failed (counterpart became unreachable mid-flight) —
                    // fall back to queued transfer for background delivery.
                    self?.session.transferUserInfo(["phoneWatchMessage": payload])
                }
            } else {
                // Counterpart not reachable — use background-queued transfer.
                session.transferUserInfo(["phoneWatchMessage": payload])
            }
        } catch {
            // Encoding failures are non-fatal for fire-and-forget messages.
        }
    }

    /// B.8.2 Issue #3: deliver via `WCSession.updateApplicationContext`. The OS
    /// keeps only the latest payload — repeated calls intentionally overwrite.
    /// Reserve `queueMessage` (transferUserInfo) for non-coalescable events
    /// (modeSwitch, pairingHandoff, manual user actions); use this method for
    /// coalescable state snapshots that should always read "latest only".
    ///
    /// The 8KB warning is log-only and does NOT block delivery — B.8.4 will
    /// inherit the size signal in HV-1 telemetry to decide if a file-pointer
    /// fallback is needed once buffers populate in production.
    ///
    /// Note: this method is intentionally not declared on the `PhoneWatchTransport`
    /// protocol — the only consumer is the `SnapshotTransport` extension in
    /// `AlgorithmStateSnapshotEmitter.swift`, so the protocol's external
    /// contract does not need to grow.
    public func sendApplicationContext(_ message: PhoneWatchMessage) {
        do {
            let data = try encoder.encode(message)
            if data.count > 8 * 1024 {
                log.default("sendApplicationContext: payload size %d bytes exceeds 8KB safety budget; B.8.4 will need fallback strategy", data.count)
            }
            let context: [String: Any] = ["phoneWatchMessage": data]
            try session.updateApplicationContext(context)
        } catch {
            log.error("sendApplicationContext failed: %{public}@", String(describing: error))
        }
    }

    /// Public hook called by WatchDataManager when a `WCSession` callback
    /// arrives that the host has identified as PhoneWatchMessage traffic.
    /// `replyHandler` is non-nil only for `didReceiveMessageData` paths.
    public func handleIncomingMessageData(_ data: Data, replyHandler: ((Data) -> Void)?) {
        do {
            let message = try decoder.decode(PhoneWatchMessage.self, from: data)
            onIncomingMessage?(message)
            replyHandler?(data)  // echo as default reply
        } catch {
            replyHandler?(Data())
        }
    }
}

public enum PhoneWatchTransportError: Error {
    case counterpartNotReachable
    case invalidReply
}
