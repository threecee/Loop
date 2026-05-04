//
//  ReconciliationFixtureGenerator.swift
//  LoopTests
//
//  B.8.4 reconciliation activation: programmatic fixture synthesis.
//
//  This file lives in `LoopTests` purely as a one-shot generator: running
//  `test_generateAllFixtures` writes 3 JSON fixtures to /tmp suitable for
//  copying into `LoopAlgorithmReconciliationTests/Fixtures/`. The fixtures
//  carry a programmatically-built `LoopPredictionInput` (with realistic
//  schedules + scenario-shaped buffers) and a captured `expectedOutput`
//  produced by `LoopAlgorithm.generatePrediction`.
//
//  Why programmatic instead of LLDB-captured-from-real-iteration?
//   - Sim-friendly + reproducible: any developer can regenerate fixtures.
//   - Path α equivalence — `WatchAlgorithmDriver.runForReconciliation`
//     runs the same `LoopAlgorithm.generatePrediction` against the same
//     `LoopPredictionInput`, so the test reduces to "did Codable
//     round-trip preserve the input bit-for-bit." That's the load-bearing
//     property: drift comes from serialization mistakes or LoopKit pin
//     advances, not from algorithm divergence (the algorithm is a single
//     upstream symbol).
//
//  The test is gated `#if DEBUG` and skipped by default — it only runs
//  when invoked directly via `-only-testing:LoopTests/ReconciliationFixtureGenerator`.
//  Once the 3 fixture JSON files are in place, the generator is no
//  longer needed for routine CI; it stays around for re-generation if
//  LoopKit's wire format ever changes.
//

#if DEBUG

import XCTest
import HealthKit
import LoopKit
@testable import LoopAlgorithmCore

final class ReconciliationFixtureGenerator: XCTestCase {

    /// Anchor time for all fixtures. Chosen to be a stable past timestamp so
    /// fixture content is deterministic across regenerations.
    private static let anchor = ISO8601DateFormatter().date(from: "2026-05-03T14:30:00Z")!

    // MARK: - Public entrypoint (generates all 3 fixtures)

    /// Run via:
    ///   xcodebuild test -workspace LoopWorkspace.xcworkspace \
    ///     -scheme LoopWorkspace -destination 'platform=iOS Simulator,name=iPhone 17' \
    ///     -only-testing:LoopTests/ReconciliationFixtureGenerator/test_generateAllFixtures
    /// Skipped by default so it doesn't fight the regular test suite.
    func test_generateAllFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GENERATE_RECONCILIATION_FIXTURES"] == "1",
                          "Set GENERATE_RECONCILIATION_FIXTURES=1 to regenerate fixture JSON files")

        try generateFixture(name: "steady-state",
                            predictionInput: makeSteadyStateInput())
        try generateFixture(name: "post-meal-carbs",
                            predictionInput: makePostMealCarbsInput())
        try generateFixture(name: "predicted-hypo",
                            predictionInput: makePredictedHypoInput())
    }

    // MARK: - Fixture writer

    private func generateFixture(name: String, predictionInput: LoopPredictionInput) throws {
        let prediction = try LoopAlgorithm.generatePrediction(
            input: predictionInput,
            startDate: Self.anchor
        )

        let fixture = LoopAlgorithmReconciliationFixture(
            name: name,
            capturedAt: Self.anchor,
            input: CapturedAlgorithmInput(
                predictionInput: predictionInput,
                predictionDate: Self.anchor,
                doseRecommendationType: .tempBasal
            ),
            expectedOutput: CapturedAlgorithmOutput(
                predictedGlucose: prediction.glucose,
                doseRecommendation: AutomaticDoseRecommendation(basalAdjustment: nil)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)

        let url = URL(fileURLWithPath: "/tmp/loop-reconciliation-\(name).json")
        try data.write(to: url, options: .atomic)
        print("[B.8.4-activation] Wrote fixture \(name) (\(data.count) bytes, \(prediction.glucose.count) predicted points) → \(url.path)")
    }

    // MARK: - Scenario builders

    /// Steady-state: flat-ish in-range glucose (~100 mg/dL), only basal
    /// insulin history, no carbs. Algorithm should predict roughly stable
    /// glucose.
    private func makeSteadyStateInput() -> LoopPredictionInput {
        let now = Self.anchor

        // 12 glucose samples, every 5 minutes, all near 100 mg/dL (+/- 2).
        let glucose: [StoredGlucoseSample] = (0..<12).map { i in
            let date = now.addingTimeInterval(TimeInterval(-5 * 60 * (11 - i)))
            let value = 100.0 + Double((i % 3) - 1) * 2.0  // 98 / 100 / 102 cycle
            return StoredGlucoseSample(
                startDate: date,
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
                isDisplayOnly: false
            )
        }

        // Basal-only dose history covering t-16h to t at 1.0 U/h scheduled basal.
        let doses = makeContinuousBasalDoses(rate: 1.0, hoursBack: 16, anchor: now)

        return LoopPredictionInput(
            glucoseHistory: glucose,
            doses: doses,
            carbEntries: [],
            settings: makeSettings(anchor: now)
        )
    }

    /// Post-meal-carbs: flat-ish glucose, recent 30g carb entry 30 minutes
    /// ago with absorption still active.
    private func makePostMealCarbsInput() -> LoopPredictionInput {
        let now = Self.anchor

        // 12 glucose samples, slightly rising from 95 → 130.
        let glucose: [StoredGlucoseSample] = (0..<12).map { i in
            let date = now.addingTimeInterval(TimeInterval(-5 * 60 * (11 - i)))
            let value = 95.0 + Double(i) * 3.0  // 95, 98, 101, ..., 128
            return StoredGlucoseSample(
                startDate: date,
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
                isDisplayOnly: false
            )
        }

        let doses = makeContinuousBasalDoses(rate: 1.0, hoursBack: 16, anchor: now)

        let carb = StoredCarbEntry(
            startDate: now.addingTimeInterval(-30 * 60),
            quantity: HKQuantity(unit: .gram(), doubleValue: 30.0),
            absorptionTime: 3 * 60 * 60  // 3-hour absorption (medium)
        )

        return LoopPredictionInput(
            glucoseHistory: glucose,
            doses: doses,
            carbEntries: [carb],
            settings: makeSettings(anchor: now)
        )
    }

    /// Predicted-hypo: glucose trending down, no carbs, recent bolus that's
    /// still active. Algorithm should predict glucose dipping below the
    /// suspend threshold.
    private func makePredictedHypoInput() -> LoopPredictionInput {
        let now = Self.anchor

        // 12 glucose samples, falling from 130 → 80 mg/dL.
        let glucose: [StoredGlucoseSample] = (0..<12).map { i in
            let date = now.addingTimeInterval(TimeInterval(-5 * 60 * (11 - i)))
            let value = 130.0 - Double(i) * 4.5  // 130, 125.5, 121, ..., ~80
            return StoredGlucoseSample(
                startDate: date,
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
                isDisplayOnly: false
            )
        }

        var doses = makeContinuousBasalDoses(rate: 1.0, hoursBack: 16, anchor: now)
        // Add a bolus 1 hour ago that's still active.
        let bolus = DoseEntry(
            type: .bolus,
            startDate: now.addingTimeInterval(-60 * 60),
            endDate: now.addingTimeInterval(-60 * 60 + 30),
            value: 2.0,
            unit: .units
        )
        doses.append(bolus)
        doses.sort { $0.startDate < $1.startDate }

        return LoopPredictionInput(
            glucoseHistory: glucose,
            doses: doses,
            carbEntries: [],
            settings: makeSettings(anchor: now)
        )
    }

    // MARK: - Settings + dose helpers

    /// Realistic schedules covering t-24h .. t+6h. Single segment per
    /// schedule keeps fixtures small while satisfying the algorithm's
    /// `closestPrior` lookups.
    private func makeSettings(anchor: Date) -> LoopAlgorithmSettings {
        let scheduleStart = anchor.addingTimeInterval(-24 * 60 * 60)
        let scheduleEnd = anchor.addingTimeInterval(6 * 60 * 60)

        let basal = [AbsoluteScheduleValue(
            startDate: scheduleStart,
            endDate: scheduleEnd,
            value: 1.0  // 1 U/h
        )]
        let sensitivity = [AbsoluteScheduleValue(
            startDate: scheduleStart,
            endDate: scheduleEnd,
            value: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 50.0)
        )]
        let carbRatio = [AbsoluteScheduleValue(
            startDate: scheduleStart,
            endDate: scheduleEnd,
            value: 10.0  // 10 g/U
        )]
        let target = [AbsoluteScheduleValue(
            startDate: scheduleStart,
            endDate: scheduleEnd,
            value: ClosedRange(
                uncheckedBounds: (
                    lower: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100.0),
                    upper: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 120.0)
                )
            )
        )]

        return LoopAlgorithmSettings(
            basal: basal,
            sensitivity: sensitivity,
            carbRatio: carbRatio,
            target: target,
            maximumBasalRatePerHour: 4.0,
            maximumBolus: 10.0,
            suspendThreshold: GlucoseThreshold(
                unit: .milligramsPerDeciliter,
                value: 70.0
            )
        )
    }

    /// Builds a chain of contiguous 5-minute `.basal` doses ending at `anchor`,
    /// going back `hoursBack` hours, at the given U/h rate (so each 5-minute
    /// segment delivers `rate * 5/60` units).
    private func makeContinuousBasalDoses(rate: Double, hoursBack: Int, anchor: Date) -> [DoseEntry] {
        let segmentSeconds: TimeInterval = 5 * 60
        let total = hoursBack * 12
        let unitsPerSegment = rate * 5.0 / 60.0
        return (0..<total).map { i in
            let end = anchor.addingTimeInterval(TimeInterval(-i) * segmentSeconds)
            let start = end.addingTimeInterval(-segmentSeconds)
            return DoseEntry(
                type: .basal,
                startDate: start,
                endDate: end,
                value: unitsPerSegment,
                unit: .units
            )
        }.reversed()
    }
}

#endif
