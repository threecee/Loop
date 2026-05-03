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

    init(defaults: UserDefaults = UserDefaults(suiteName: HandoffSettings.appGroupIdentifier)!) {
        self.defaults = defaults
    }

    /// The most recent snapshot received. nil until first `update(_:)`.
    var current: AlgorithmStateSnapshot? {
        guard let data = defaults.data(forKey: Self.userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(AlgorithmStateSnapshot.self, from: data)
    }

    /// Called by `PhoneWatchSessionCoordinator` when an `.algorithmStateSnapshot`
    /// message arrives. Drops the incoming snapshot if older than the cached one.
    func update(_ snapshot: AlgorithmStateSnapshot) {
        if let existing = current, snapshot.createdAt <= existing.createdAt {
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    #if DEBUG
    func resetForTesting() {
        defaults.removeObject(forKey: Self.userDefaultsKey)
    }
    #endif
}

#endif  // !os(iOS)
