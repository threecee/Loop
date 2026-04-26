//
//  BackgroundPollScheduler.swift
//  WatchApp Extension
//
//  Submits `WKApplicationRefreshBackgroundTask` requests at a 5-minute cadence
//  and, on wake, triggers a poll cycle on the registered remote-data services
//  via the supplied closure. Gates on Nightscout-configured at the trigger
//  point: if the closure returns false, nothing is done (the next refresh
//  is still scheduled so we wake up to re-check when config arrives).
//
//  B.3.a Phase 5 — Step 5.6 / 5.12.
//

#if !os(iOS)

import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

final class BackgroundPollScheduler {

    /// Production cadence: every 5 minutes, matching the watch G7 reading
    /// interval and keeping wake-ups tightly clustered.
    static let defaultCadence: TimeInterval = 5 * 60

    /// Closure returning `true` if a poll is currently meaningful (i.e.,
    /// Nightscout is configured and `WatchRemoteCommandBootstrap.manager`
    /// is non-nil). Returning `false` skips the actual poll but still
    /// reschedules.
    let shouldPoll: () -> Bool

    /// Closure invoked on wake after `shouldPoll()` returns true.
    let performPoll: () -> Void

    /// Cadence used for the next reschedule. Overridable for tests.
    let cadence: TimeInterval

    /// Test seam for `WKExtension.shared().scheduleBackgroundRefresh(...)`.
    /// Production callers leave the default; tests inject a recorder.
    let scheduler: BackgroundRefreshScheduling

    init(cadence: TimeInterval = BackgroundPollScheduler.defaultCadence,
         shouldPoll: @escaping () -> Bool,
         performPoll: @escaping () -> Void,
         scheduler: BackgroundRefreshScheduling = WKExtensionScheduler()) {
        self.cadence = cadence
        self.shouldPoll = shouldPoll
        self.performPoll = performPoll
        self.scheduler = scheduler
    }

    /// Schedule the next background-refresh wake-up. Call from
    /// `applicationDidFinishLaunching`, after `applicationWillResignActive`,
    /// and after each wake.
    func scheduleNext(at date: Date = Date().addingTimeInterval(BackgroundPollScheduler.defaultCadence)) {
        scheduler.scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { _ in
            // No-op on error; system retries automatically. We don't block
            // task processing on failed scheduling.
        }
    }

    /// Called from `ExtensionDelegate.handle(_:)` for each
    /// `WKApplicationRefreshBackgroundTask`. Triggers a poll if the
    /// gating closure returns true, then reschedules the next wake.
    func handleWake() {
        if shouldPoll() {
            performPoll()
        }
        scheduleNext()
    }
}

// MARK: - Scheduling protocol (test seam)

protocol BackgroundRefreshScheduling {
    func scheduleBackgroundRefresh(withPreferredDate date: Date,
                                   userInfo: (NSSecureCoding & NSObjectProtocol)?,
                                   scheduledCompletion: @escaping (Error?) -> Void)
}

#if canImport(WatchKit)
struct WKExtensionScheduler: BackgroundRefreshScheduling {
    func scheduleBackgroundRefresh(withPreferredDate date: Date,
                                   userInfo: (NSSecureCoding & NSObjectProtocol)?,
                                   scheduledCompletion: @escaping (Error?) -> Void) {
        WKExtension.shared().scheduleBackgroundRefresh(
            withPreferredDate: date,
            userInfo: userInfo,
            scheduledCompletion: scheduledCompletion
        )
    }
}
#else
// Fallback for non-watch builds (shouldn't happen given the file gate, but
// keeps tooling happy when previewing the file standalone).
struct WKExtensionScheduler: BackgroundRefreshScheduling {
    func scheduleBackgroundRefresh(withPreferredDate date: Date,
                                   userInfo: (NSSecureCoding & NSObjectProtocol)?,
                                   scheduledCompletion: @escaping (Error?) -> Void) {
        scheduledCompletion(nil)
    }
}
#endif

#endif  // !os(iOS)
