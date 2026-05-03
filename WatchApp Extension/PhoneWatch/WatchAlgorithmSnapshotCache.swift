//
//  WatchAlgorithmSnapshotCache.swift
//  WatchApp Extension
//
//  B.8: watch-side store for the most recent AlgorithmStateSnapshot received
//  from the phone. Persists to App Group UserDefaults so it survives process
//  death. Drops out-of-order snapshots based on createdAt.
//

#if !os(iOS)

import Foundation
import OmniBLE

final class WatchAlgorithmSnapshotCache {

    static let shared = WatchAlgorithmSnapshotCache()

    static let userDefaultsKey = "loop-and-learn.algorithmStateSnapshot"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = HandoffSettings.appGroupDefaults
        }
    }

    /// The most recent snapshot received. nil until first `update(_:)`.
    var current: AlgorithmStateSnapshot? {
        return defaults.codableValue(forKey: Self.userDefaultsKey, as: AlgorithmStateSnapshot.self)
    }

    /// Stores the snapshot if it's newer than the cached one (monotonic guard).
    ///
    /// **Concurrency precondition:** callers MUST invoke this serially on a
    /// single queue. The read-then-write is not atomic — concurrent calls can
    /// race and let an older snapshot overwrite a newer one. Today this holds
    /// because all callers (PhoneWatchSessionCoordinator's WCSession callback
    /// dispatch) are already serialized; if you add a new caller, ensure
    /// it shares that queue or wrap update calls in your own lock.
    ///
    /// Called by `PhoneWatchSessionCoordinator` when an `.algorithmStateSnapshot`
    /// message arrives. Drops the incoming snapshot if older than the cached one.
    func update(_ snapshot: AlgorithmStateSnapshot) {
        if let existing = current, snapshot.createdAt <= existing.createdAt {
            return
        }
        defaults.set(codable: snapshot, forKey: Self.userDefaultsKey)
    }

    #if DEBUG
    func resetForTesting() {
        defaults.removeObject(forKey: Self.userDefaultsKey)
    }
    #endif
}

#endif  // !os(iOS)
