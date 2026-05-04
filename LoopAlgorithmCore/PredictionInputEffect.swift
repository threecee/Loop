//
//  PredictionInputEffect.swift
//  LoopAlgorithmCore
//
//  Created by Nate Racklyeft on 9/4/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit


public struct PredictionInputEffect: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let carbs            = PredictionInputEffect(rawValue: 1 << 0)
    public static let insulin          = PredictionInputEffect(rawValue: 1 << 1)
    public static let momentum         = PredictionInputEffect(rawValue: 1 << 2)
    public static let retrospection    = PredictionInputEffect(rawValue: 1 << 3)
    public static let suspend          = PredictionInputEffect(rawValue: 1 << 4)

    public static let all: PredictionInputEffect = [.carbs, .insulin, .momentum, .retrospection]

    public var localizedTitle: String? {
        switch self {
        case [.carbs]:
            return NSLocalizedString("Carbohydrates", comment: "Title of the prediction input effect for carbohydrates")
        case [.insulin]:
            return NSLocalizedString("Insulin", comment: "Title of the prediction input effect for insulin")
        case [.momentum]:
            return NSLocalizedString("Glucose Momentum", comment: "Title of the prediction input effect for glucose momentum")
        case [.retrospection]:
            return NSLocalizedString("Retrospective Correction", comment: "Title of the prediction input effect for retrospective correction")
        case [.suspend]:
            return NSLocalizedString("Suspension of Insulin Delivery", comment: "Title of the prediction input effect for suspension of insulin delivery")
        default:
            return nil
        }
    }

    public func localizedDescription(forGlucoseUnit unit: HKUnit) -> String? {
        switch self {
        case [.carbs]:
            return String(format: NSLocalizedString("Carbs Absorbed (g) ÷ Carb Ratio (g/U) × Insulin Sensitivity (%1$@/U)", comment: "Description of the prediction input effect for carbohydrates. (1: The glucose unit string)"), unit.localizedShortUnitString)
        case [.insulin]:
            return String(format: NSLocalizedString("Insulin Absorbed (U) × Insulin Sensitivity (%1$@/U)", comment: "Description of the prediction input effect for insulin"), unit.localizedShortUnitString)
        case [.momentum]:
            return NSLocalizedString("15 min glucose regression coefficient (b₁), continued with decay over 30 min", comment: "Description of the prediction input effect for glucose momentum")
        case [.retrospection]:
            return NSLocalizedString("30 min comparison of glucose prediction vs actual, continued with decay over 60 min", comment: "Description of the prediction input effect for retrospective correction")
        case [.suspend]:
             return NSLocalizedString("Glucose effect of suspending insulin delivery", comment: "Description of the prediction input effect for suspension of insulin delivery")
        default:
            return nil
        }
    }
}

public extension PredictionInputEffect {
    /// B.8.5: canonical "all effects enabled" constant. Both
    /// `LoopSettings.enabledEffects` (iOS) and
    /// `LoopSettings.loopAlgorithmCore_enabledEffects` (LoopAlgorithmCore)
    /// delegate here. Replaces two duplicated `.all` returns + a
    /// `LoopConstants.retrospectiveCorrectionEnabled`-gated subtraction.
    static let allEnabled: PredictionInputEffect = .all
}
