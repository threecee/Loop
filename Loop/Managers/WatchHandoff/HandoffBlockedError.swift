//
//  HandoffBlockedError.swift
//  Loop (iOS)
//
// friendly LocalizedError used by iOS UI sites that
//  detect a handoff-blocked condition (the OmniBLE command gate fired
//  PumpManagerError.uncertainDelivery while HandoffOrchestrator's
//  ownership.commandsAllowed is false).
//
//  The gate's underlying signal is `.uncertainDelivery` (mirror of
//  B.5 Phase 2A's precedent — OmniBLE submodule cannot import Loop, so
//  it cannot use LoopError directly). When that error reaches a UI site
//  AND we know we're mid-handoff, we substitute this friendly message
//  instead of the misleading "uncertain delivery" string.
//
//  Loop-internal type — does NOT cross WCSession.
//

import Foundation

enum HandoffBlockedError: LocalizedError {
    /// The user attempted a pump action while a phone↔watch handoff was
    /// in progress. The action was not sent to the pod; the user can
    /// retry once the handoff completes (typically a few seconds).
    case handoffInProgress

    var errorDescription: String? {
        switch self {
        case .handoffInProgress:
            return NSLocalizedString(
                "A handoff between iPhone and Apple Watch is in progress. Please try again in a few seconds.",
                comment: "Alert body shown when a pump action is blocked because a phone↔watch handoff is in progress (B.5.2)"
            )
        }
    }
}
