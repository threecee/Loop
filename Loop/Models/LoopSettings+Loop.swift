//
//  LoopSettings+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopAlgorithmCore
import LoopCore

// MARK: - Static configuration
extension LoopSettings {
    var enabledEffects: PredictionInputEffect {
        // B.8.5: delegate to canonical `PredictionInputEffect.allEnabled` in
        // LoopAlgorithmCore. The retrospective-correction toggle is hard-coded
        // true today (`LoopConstants.retrospectiveCorrectionEnabled`); when/if
        // it becomes user-configurable, this `guard` branch becomes
        // load-bearing — until then both branches converge on the same
        // canonical constant.
        guard LoopConstants.retrospectiveCorrectionEnabled else {
            return PredictionInputEffect.allEnabled.subtracting(.retrospection)
        }
        return PredictionInputEffect.allEnabled
    }
}
