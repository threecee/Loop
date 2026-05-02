//
//  WatchSettingsCache.swift
//  WatchApp Extension
//
//  Watch-side store for the most recent `PhoneWatchSettingsSync` received
//  from the phone. Thread-safe; the main-actor check in `ExtensionDelegate`
//  means updates always arrive on the main thread, but the `current` accessor
//  is intentionally synchronous for callers on any queue.
//
//  B.3.a Phase 6.
//

#if !os(iOS)

import Foundation
import OmniBLE

/// Singleton cache for the latest phone→watch settings sync payload.
/// `WatchAlgorithmBootstrap` and `WatchRemoteCommandBootstrap` read from this
/// cache via `WatchSettingsCache.shared.current` in their `settingsProvider`
/// closures.
final class WatchSettingsCache {

    static let shared = WatchSettingsCache()

    /// Production code uses `WatchSettingsCache.shared`. The `internal`
    /// visibility lets tests create isolated instances without sharing the
    /// singleton state.
    init() {}

    /// The most recent settings sync received from the phone.
    /// `nil` until the first sync arrives.
    private(set) var current: PhoneWatchSettingsSync?

    /// Called by `ExtensionDelegate` when a `.settingsSync` message arrives.
    func update(_ sync: PhoneWatchSettingsSync) {
        current = sync
    }

    /// B.5: test-only helper to clear the singleton between test runs.
    /// Production never calls this — once a sync arrives, it stays cached.
    func resetForTesting() {
        current = nil
    }
}

#endif  // !os(iOS)
