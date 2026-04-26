//
//  HKUnit+LocalizedString.swift
//  LoopAlgorithmCore
//
//  Provides localizedShortUnitString for glucose and insulin units so
//  PredictionInputEffect.localizedDescription(forGlucoseUnit:) can compile
//  inside the framework without relying on LoopKit's internal HKUnit extensions.
//
//  Mirrors Loop/Common/Extensions/HKUnit.swift (same logic, same localizations).
//

import HealthKit

extension HKUnit {
    // Construct well-known units without using LoopKit's internal static shorthands
    private static let _milligramsPerDeciliter: HKUnit =
        HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
    private static let _millimolesPerLiter: HKUnit =
        HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())

    var localizedShortUnitString: String {
        if self == HKUnit._millimolesPerLiter {
            return NSLocalizedString("mmol/L", comment: "The short unit display string for millimoles of glucose per liter")
        } else if self == HKUnit._milligramsPerDeciliter {
            return NSLocalizedString("mg/dL", comment: "The short unit display string for milligrams of glucose per decilter")
        } else if self == .internationalUnit() {
            return NSLocalizedString("U", comment: "The short unit display string for international units of insulin")
        } else if self == .gram() {
            return NSLocalizedString("g", comment: "The short unit display string for grams")
        } else {
            return String(describing: self)
        }
    }
}
