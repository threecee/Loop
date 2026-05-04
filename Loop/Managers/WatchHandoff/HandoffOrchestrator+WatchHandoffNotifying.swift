//
//  HandoffOrchestrator+WatchHandoffNotifying.swift
//  Loop (iOS)
//
//  Bridges `LoopDataManager`'s non-isolated settings-change callsite into
//  the orchestrator's `@MainActor` world. The protocol method is
//  `nonisolated` (callable from any isolation context) and hops to
//  MainActor before invoking `emitSettingsSync()`. Equivalent to the
//  existing `notifySettingsChanged()` trigger but reachable from the
//  `LoopAlgorithmRunnerDelegate` callback.
//
//  B.10: lives on the iOS Loop side because `WatchHandoffNotifying` is a
//  Loop-private protocol (defined in LoopDataManager.swift); keeping the
//  conformance there avoids dragging the protocol into OmniBLE.
//

import Foundation
import OmniBLE

extension HandoffOrchestrator: WatchHandoffNotifying {
    nonisolated func notifySettingsChangedFromAlgorithm() {
        Task { @MainActor [weak self] in
            self?.emitSettingsSync()
        }
    }
}
