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
        var inputs = PredictionInputEffect.all
        if !LoopConstants.retrospectiveCorrectionEnabled {
            inputs.remove(.retrospection)
        }
        return inputs
    }    
}
