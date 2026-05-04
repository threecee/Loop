//
//  WatchSettingsCache.swift
//  WatchApp Extension
//
//  Watch-side store for the most recent `PhoneWatchSettingsSync` received
//  from the phone. Persists the last-good across process death (App Group
//  UserDefaults) so bootstraps can run from a cold start without waiting
//  for a fresh phone sync (B.8.3).
//
//  Thread-safe enough for the watch's main-thread invariant: the
//  ExtensionDelegate dispatch always lands here on main, and subscribers
//  attach `.receive(on: DispatchQueue.main)` if they need it.
//
//  B.3.a Phase 6, B.8.2 dedup, B.8.3 publisher + persistence.
//

#if !os(iOS)

import Foundation
import Combine
import OmniBLE

/// Singleton cache for the latest phone→watch settings sync payload.
/// `WatchAlgorithmBootstrap` and `WatchRemoteCommandBootstrap` read from this
/// cache via `WatchSettingsCache.shared.current` in their `settingsProvider`
/// closures, AND subscribe to `WatchSettingsCache.shared.publisher` (B.8.3)
/// for retry-on-emit semantics.
final class WatchSettingsCache {

    static let shared = WatchSettingsCache()

    /// CurrentValueSubject so subscribers added after launch hydration get
    /// the cached value immediately on subscribe (no race vs. fresh sync arrival).
    /// Subscribers that only want change events can `.dropFirst()`.
    private let subject = CurrentValueSubject<PhoneWatchSettingsSync?, Never>(nil)

    /// Publisher of current + future settings. Latest-only semantics — every
    /// subscriber sees the current value on subscribe + every subsequent
    /// `update(_:)` that passes the equality short-circuit.
    var publisher: AnyPublisher<PhoneWatchSettingsSync?, Never> {
        subject.eraseToAnyPublisher()
    }

    /// The most recent settings sync received from the phone, OR the value
    /// hydrated from App Group UserDefaults at init. `nil` only if the watch
    /// has NEVER received a sync in any session.
    var current: PhoneWatchSettingsSync? { subject.value }

    private let appGroupDefaults: UserDefaults
    private static let lastGoodKey = "WatchSettingsCache.lastGood"

    /// Production code uses `WatchSettingsCache.shared`. The injected
    /// `appGroupDefaults` parameter lets tests pass an isolated suite to
    /// avoid sharing the App Group's shared state across runs.
    init(appGroupDefaults: UserDefaults = HandoffSettings.appGroupDefaults) {
        self.appGroupDefaults = appGroupDefaults
        // hydrate from disk so bootstraps can run before any fresh
        // .settingsSync arrives in this session (e.g., extension relaunch
        // while phone is unreachable).
        if let hydrated = appGroupDefaults.codableValue(forKey: Self.lastGoodKey,
                                                        as: PhoneWatchSettingsSync.self) {
            subject.send(hydrated)
        }
    }

    /// Called by `ExtensionDelegate` when a `.settingsSync` message arrives.
    func update(_ sync: PhoneWatchSettingsSync) {
        // B.8.2 dedup guard preserved.
        guard sync != current else { return }
        // persist BEFORE publishing so any sink that re-reads the
        // disk-backed store on emission sees a consistent value.
        appGroupDefaults.set(codable: sync, forKey: Self.lastGoodKey)
        subject.send(sync)
    }

    #if DEBUG
    /// test-only helper to clear the singleton between test runs.
    /// also clears the persisted disk state so each test starts from
    /// a known baseline. Production never calls this — once a sync arrives,
    /// it stays cached. `#if DEBUG`-guarded (B.5.1) to make accidental
    /// production calls a compile-time error rather than a runtime footgun.
    func resetForTesting() {
        subject.send(nil)
        appGroupDefaults.removeObject(forKey: Self.lastGoodKey)
    }
    #endif
}

#endif  // !os(iOS)
