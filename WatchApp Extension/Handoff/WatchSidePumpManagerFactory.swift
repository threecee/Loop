//
//  WatchSidePumpManagerFactory.swift
//  WatchApp Extension (watchOS)
//
//  Factory helper used by ExtensionDelegate's `HandoffOrchestrator`
//  bootstrap to lazily construct an `OmniBLEPumpManager` on the first
//  `.watchDriver` transition. Reads `WatchSettingsCache.shared` to seed
//  the basal schedule + max-temp-basal rate; podState is hydrated
//  post-construction by `OmniBLEOwnership.acquireBLE()` from the cached
//  pairing payload (matches the contract documented on
//  `.watchSideDefault`).
//
//  B.10: extracted from the watch-side `HandoffOrchestrator` (now lifted
//  into OmniBLE). Lives in the watch app because it touches
//  `WatchSettingsCache.shared` (a watch-app singleton).
//

import Foundation
import LoopKit
import OmniBLE

enum WatchSidePumpManagerFactory {
    /// Constructs the watch-side OmniBLEPumpManager from the most-recent
    /// received settings sync (via WatchSettingsCache). Falls back to
    /// `.watchSideDefault` if no sync has arrived yet (rare — watch
    /// becoming driver before first sync would itself be unusual).
    static func make() -> OmniBLEPumpManager {
        guard let sync = WatchSettingsCache.shared.current else {
            return OmniBLEPumpManager(state: .watchSideDefault)
        }
        let basalSchedule: BasalSchedule
        if sync.basalScheduleItems.isEmpty {
            basalSchedule = BasalSchedule(entries: [])
        } else {
            basalSchedule = BasalSchedule(entries: sync.basalScheduleItems.map {
                BasalScheduleEntry(rate: $0.value, startTime: $0.startTime)
            })
        }
        let state = OmniBLEPumpManagerState(
            podState: nil,                         // hydrated post-construction
            timeZone: TimeZone.current,
            basalSchedule: basalSchedule,
            insulinType: nil,                      // hydrated with podState
            maximumTempBasalRate: sync.maximumBasalRatePerHourUnits
        )
        return OmniBLEPumpManager(state: state)
    }
}
