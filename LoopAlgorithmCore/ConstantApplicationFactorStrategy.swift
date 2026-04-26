//
//  ConstantDosingStrategy.swift
//  LoopAlgorithmCore
//
//  Created by Jonas Björkert on 2023-06-03.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

public struct ConstantApplicationFactorStrategy: ApplicationFactorStrategy {
    // Inlined from LoopConstants.bolusPartialApplicationFactor (Loop app target).
    // Percentage of recommended dose to apply as bolus when using automatic bolus dosing strategy.
    public static let bolusPartialApplicationFactor = 0.4

    public init() {}

    public func calculateDosingFactor(
        for glucose: HKQuantity,
        correctionRangeSchedule: GlucoseRangeSchedule,
        settings: LoopSettings
    ) -> Double {
        // The original strategy uses a constant dosing factor.
        return ConstantApplicationFactorStrategy.bolusPartialApplicationFactor
    }
}
