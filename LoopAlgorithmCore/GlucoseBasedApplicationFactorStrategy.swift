//
//  GlucoseBasedApplicationFactorStrategy.swift
//  LoopAlgorithmCore
//
//  Created by Jonas Björkert on 2023-06-03.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

public struct GlucoseBasedApplicationFactorStrategy: ApplicationFactorStrategy {
    public static let minPartialApplicationFactor = 0.20 // min fraction of correction when glucose > minGlucoseSlidingScale
    public static let maxPartialApplicationFactor = 0.80 // max fraction of correction when glucose > maxGlucoseSlidingScale
    // set minGlucoseSlidingScale based on user setting for correction range
    // use mg/dL for calculations
    public static let minGlucoseDeltaSlidingScale = 10.0 // mg/dL
    public static let maxGlucoseSlidingScale = 200.0 // mg/dL

    public init() {}

    public func calculateDosingFactor(
        for glucose: HKQuantity,
        correctionRangeSchedule: GlucoseRangeSchedule,
        settings: LoopSettings
    ) -> Double {
        // Construct mg/dL unit without relying on LoopKit's internal static shorthand
        let mgdL = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

        // Calculate current glucose and lower bound target
        let currentGlucose = glucose.doubleValue(for: mgdL)
        let correctionRange = correctionRangeSchedule.quantityRange(at: Date())
        let lowerBoundTarget = correctionRange.lowerBound.doubleValue(for: mgdL)

        // Calculate minimum glucose sliding scale and scaling fraction
        let minGlucoseSlidingScale = GlucoseBasedApplicationFactorStrategy.minGlucoseDeltaSlidingScale + lowerBoundTarget
        let scalingFraction = (GlucoseBasedApplicationFactorStrategy.maxPartialApplicationFactor - GlucoseBasedApplicationFactorStrategy.minPartialApplicationFactor) / (GlucoseBasedApplicationFactorStrategy.maxGlucoseSlidingScale - minGlucoseSlidingScale)
        let scalingGlucose = max(currentGlucose - minGlucoseSlidingScale, 0.0)

        // Calculate effectiveBolusApplicationFactor
        let effectiveBolusApplicationFactor = min(GlucoseBasedApplicationFactorStrategy.minPartialApplicationFactor + scalingGlucose * scalingFraction, GlucoseBasedApplicationFactorStrategy.maxPartialApplicationFactor)

        return effectiveBolusApplicationFactor
    }
}
