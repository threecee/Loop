//
//  LoopAlgorithmReconciliationFixture.swift
//  LoopAlgorithmCore
//
//  Created for B.8.4 Phase 5a: snapshot-hydration reconciliation testing.
//
//  Defines the on-disk JSON fixture format used by
//  `LoopAlgorithmRunner.captureFixtureForReconciliation(name:)` (DEBUG-only)
//  and the Phase 5b `LoopAlgorithmReconciliationTests` target. The fixture
//  bundles a captured iteration's input and the runner's expected output so
//  the watch-side driver can replay the same input offline and assert that
//  it produces the same output.
//
//  Why wrappers (`CapturedAlgorithmInput` / `CapturedAlgorithmOutput`)
//  instead of `LoopKit.LoopAlgorithmInput` / `LoopKit.LoopAlgorithmOutput`
//  directly?
//
//   - `LoopAlgorithmInput` is a `public struct` in LoopKit with no public
//     memberwise initializer (the synthesized init is `internal`) and no
//     Codable conformance. Adding either via cross-module extension is
//     blocked: a public init can't reach the synthesized internal init it
//     would need to delegate to, and retroactive Codable conformance on
//     LoopKit-owned types triggers Swift's "imported type" warning and
//     cross-module synthesis limits.
//
//   - `LoopAlgorithmOutput` is Codable in LoopKit but likewise has only
//     `init(from decoder:)` — no public memberwise init for our shim to
//     construct one in `LoopDataManager.loopAlgorithmRunnerDidFinishLoop`.
//
//   - Modifying LoopKit's submodule pin would push Phase 5a beyond its
//     "single Loop commit" budget and mix algorithm-core changes with the
//     instrumentation. Wrappers keep the change contained.
//
//  The wrappers carry exactly the fields the reconciliation tests need.
//  Phase 5b's `WatchAlgorithmDriver.runForReconciliation(_:)` will pick the
//  wrapper apart and feed `glucoseHistory` / `doses` / `carbEntries` into
//  the watch's snapshot-hydration path the same way a real snapshot would.
//

import Foundation
import LoopKit

// MARK: - Captured input wrapper

/// B.8.4 Phase 5a: Loop-side mirror of `LoopAlgorithmInput`. Holds the same
/// three fields (`predictionInput`, `predictionDate`, `doseRecommendationType`)
/// in a form that's Codable and externally constructible without modifying
/// LoopKit. The reconciliation tests reconstruct the runner's input from
/// these fields.
public struct CapturedAlgorithmInput: Codable {
    public let predictionInput: LoopPredictionInput
    public let predictionDate: Date
    public let doseRecommendationType: String  // mirrors DoseRecommendationType.rawValue

    public init(
        predictionInput: LoopPredictionInput,
        predictionDate: Date,
        doseRecommendationType: String
    ) {
        self.predictionInput = predictionInput
        self.predictionDate = predictionDate
        self.doseRecommendationType = doseRecommendationType
    }

    /// Convenience initializer accepting the LoopKit enum directly.
    public init(
        predictionInput: LoopPredictionInput,
        predictionDate: Date,
        doseRecommendationType: DoseRecommendationType
    ) {
        self.predictionInput = predictionInput
        self.predictionDate = predictionDate
        self.doseRecommendationType = doseRecommendationType.rawValue
    }
}

// MARK: - Captured output wrapper

/// B.8.4 Phase 5a: Loop-side mirror of `LoopAlgorithmOutput`. Holds the same
/// two fields (`predictedGlucose`, `doseRecommendation`); both element types
/// are already Codable in LoopKit.
public struct CapturedAlgorithmOutput: Codable {
    public let predictedGlucose: [PredictedGlucoseValue]
    public let doseRecommendation: AutomaticDoseRecommendation

    public init(
        predictedGlucose: [PredictedGlucoseValue],
        doseRecommendation: AutomaticDoseRecommendation
    ) {
        self.predictedGlucose = predictedGlucose
        self.doseRecommendation = doseRecommendation
    }
}

// MARK: - Fixture wrapper

/// B.8.4 Phase 5a: bundles one (input, expected-output) pair captured from a
/// real on-device loop iteration. Produced by
/// `LoopAlgorithmRunner.captureFixtureForReconciliation(name:)` (DEBUG only)
/// and consumed by the Phase 5b `LoopAlgorithmReconciliationTests` target,
/// which feeds the captured input into the watch-side `WatchAlgorithmDriver`
/// and asserts the watch output equals the captured `expectedOutput`.
public struct LoopAlgorithmReconciliationFixture: Codable {
    public let name: String
    public let capturedAt: Date
    public let input: CapturedAlgorithmInput
    public let expectedOutput: CapturedAlgorithmOutput

    public init(
        name: String,
        capturedAt: Date,
        input: CapturedAlgorithmInput,
        expectedOutput: CapturedAlgorithmOutput
    ) {
        self.name = name
        self.capturedAt = capturedAt
        self.input = input
        self.expectedOutput = expectedOutput
    }
}
