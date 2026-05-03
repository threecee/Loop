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

    #if DEBUG
    /// B.8.2 Issue #4: test-only counter incremented on every actual write
    /// past the equality guard. Lets the dedup test assert no-op behavior
    /// without having to mock UserDefaults. Production code never reads this.
    private(set) var writeCount: Int = 0
    #endif

    /// Called by `ExtensionDelegate` when a `.settingsSync` message arrives.
    func update(_ sync: PhoneWatchSettingsSync) {
        // B.8.2 Issue #4: skip duplicate payloads. The phone-side dedup is
        // empty after launch, so identical syncs may arrive once per app
        // start. PhoneWatchSettingsSync is Equatable; structural compare is
        // cheap and saves a publisher fire (B.8.3) + any downstream work.
        guard sync != current else { return }
        current = sync
        #if DEBUG
        writeCount += 1
        #endif
    }

    #if DEBUG
    /// B.5: test-only helper to clear the singleton between test runs.
    /// Production never calls this — once a sync arrives, it stays cached.
    /// `#if DEBUG`-guarded (B.5.1) to make accidental production calls a
    /// compile-time error rather than a runtime footgun.
    func resetForTesting() {
        current = nil
        writeCount = 0
    }
    #endif
}

#endif  // !os(iOS)
