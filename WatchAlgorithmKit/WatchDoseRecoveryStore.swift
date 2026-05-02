//
//  WatchDoseRecoveryStore.swift
//  WatchAlgorithmKit
//
//  B.5 carryover from B.6 code review: skinny crash-recovery tripwire for
//  watch dose enactment. Records dose-in-flight to App Group UserDefaults
//  before calling enactBolus/enactTempBasal; clears after completion.
//  On watch app launch, ExtensionDelegate checks for stale entries and
//  logs them — NOT a full iOS-style CrashRecoveryManager analog, just
//  enough to surface "we tried to dose, then crashed" for investigation.
//

import Foundation
import os.log

public struct WatchDoseRecoveryStore {

    private static let key = "com.LoopKit.WatchAlgorithmKit.doseInFlight"
    private static let log = OSLog(subsystem: "com.loopkit.Loop.WatchApp",
                                   category: "WatchDoseRecoveryStore")

    /// Maximum age before a recorded entry is considered "stale" (= probable crash).
    public static let staleAfter: TimeInterval = 60

    /// Stored shape — small enough to fit in UserDefaults inline.
    public struct Entry: Codable, Equatable {
        public let startedAt: Date
        public let description: String

        public init(startedAt: Date, description: String) {
            self.startedAt = startedAt
            self.description = description
        }
    }

    /// Record that a dose enactment is starting. Call BEFORE
    /// pumpManager.enactBolus / enactTempBasal. Idempotent — overwrites any
    /// prior entry (we only track one in-flight dose at a time).
    public static func recordStart(description: String,
                                   to defaults: UserDefaults,
                                   now: Date = Date()) {
        let entry = Entry(startedAt: now, description: description)
        if let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: key)
        }
    }

    /// Clear the recorded entry. Call AFTER pumpManager completion fires
    /// (in BOTH success and error branches).
    public static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }

    /// Load the recorded entry, if any.
    public static func load(from defaults: UserDefaults) -> Entry? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// Inspect for stale entries on app launch. If found AND older than
    /// `staleAfter`, log + clear. Returns the stale entry (if any) for
    /// callers that want to do additional handling.
    @discardableResult
    public static func checkAndClearStale(in defaults: UserDefaults,
                                          now: Date = Date()) -> Entry? {
        guard let entry = load(from: defaults) else { return nil }
        let age = now.timeIntervalSince(entry.startedAt)
        if age > staleAfter {
            log.error("Possible interrupted dose at %{public}@ (age %.0fs): %{public}@. Pod history is the source of truth.",
                      ISO8601DateFormatter().string(from: entry.startedAt),
                      age,
                      entry.description)
            clear(from: defaults)
            return entry
        }
        // Not stale — leave it; the in-flight dose may still complete.
        return nil
    }
}
