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

    /// B.8.4: shared App Group file used as the file-pointer fallback
    /// for oversized algorithm-state snapshot payloads. Both phone and
    /// watch resolve the same path via `HandoffSettings.appGroupContainerURL`.
    private static let snapshotFileURL: URL =
        HandoffSettings.appGroupContainerURL.appendingPathComponent("snapshot.json")

    /// B.8.4: monotonically-increasing sequence number persisted in the
    /// shared App Group UserDefaults so it survives process death. The
    /// watch ignores pointer messages whose sequence is ≤ the highest it
    /// has seen, providing replay/out-of-order safety.
    private static let sequenceKey = "B.8.4.snapshotSequence"

    /// 8 KB applicationContext soft budget. Snapshots strictly larger than
    /// this fall back to the file-pointer path; smaller snapshots ride
    /// inline as before (B.8.2 path).
    private static let applicationContextSizeBudget = 8 * 1024

    public var isReachable: Bool { session.isReachable }

    public init(session: WCSession = .default) {
        self.session = session
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
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
    /// B.8.4: if a `.algorithmStateSnapshot` payload exceeds the 8 KB
    /// applicationContext budget, write the encoded payload to
    /// `<AppGroup>/snapshot.json` (atomic) and instead deliver a tiny
    /// `.algorithmStateSnapshotPointer(sequence:)` message via
    /// applicationContext. The watch sees the pointer, reads the file, and
    /// re-wraps as if the payload had arrived inline. Smaller payloads
    /// continue using the inline applicationContext path unchanged.
    ///
    /// Note: this method is intentionally not declared on the `PhoneWatchTransport`
    /// protocol — the only consumer is the `SnapshotTransport` extension in
    /// `AlgorithmStateSnapshotEmitter.swift`, so the protocol's external
    /// contract does not need to grow.
    public func sendApplicationContext(_ message: PhoneWatchMessage) {
        do {
            let data = try encoder.encode(message)

            // file-pointer fallback for oversized snapshot payloads.
            if case .algorithmStateSnapshot = message,
               data.count > Self.applicationContextSizeBudget {
                try data.write(to: Self.snapshotFileURL, options: .atomic)
                let nextSeq = nextSnapshotSequence()
                let pointer = PhoneWatchMessage.algorithmStateSnapshotPointer(sequence: nextSeq)
                let pointerData = try encoder.encode(pointer)
                let context: [String: Any] = ["phoneWatchMessage": pointerData]
                try session.updateApplicationContext(context)
                log.default("sendApplicationContext: large snapshot (%d bytes) written to file; sent pointer seq=%llu",
                            data.count, nextSeq)
                return
            }

            // Small payload — use applicationContext directly (B.8.2 path).
            let context: [String: Any] = ["phoneWatchMessage": data]
            try session.updateApplicationContext(context)
        } catch {
            log.error("sendApplicationContext failed: %{public}@", String(describing: error))
        }
    }

    /// B.8.4: monotonic sequence number for snapshot-pointer messages.
    /// Persisted in App Group UserDefaults under `sequenceKey` so it
    /// survives phone process death; reset to 0 only if the App Group
    /// container is deleted (full app uninstall).
    ///
    /// `UInt64` does not round-trip cleanly through UserDefaults' `Any?` —
    /// values larger than `Int64.max` would coerce to `Double` and lose
    /// precision. We store as `Int64` (and read it back) since a strictly
    /// monotonic counter incremented every loop iteration cannot realistically
    /// approach `Int64.max` (2⁶³ - 1 ≈ 9.2 × 10¹⁸) in any human lifetime.
    private func nextSnapshotSequence() -> UInt64 {
        let defaults = HandoffSettings.appGroupDefaults
        let current = defaults.object(forKey: Self.sequenceKey) as? Int64 ?? 0
        let next = current &+ 1  // wrapping add — defensive, see comment above
        defaults.set(next, forKey: Self.sequenceKey)
        return UInt64(bitPattern: next)
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
