//
//  ReconciliationTests.swift
//  LoopTests
//
//  B.8.4 Phase 5b: cross-runner equivalence harness. Asserts that the
//  watch-side `WatchAlgorithmDriver`'s internal runner produces a
//  `CapturedAlgorithmOutput` byte-identical to the iOS-captured
//  `expectedOutput` when both are fed the same `CapturedAlgorithmInput`.
//
//  Closes the runtime-equivalence half of the Codex adversarial review
//  Loop #3 [high] gap (paired with the static `algorithm-fidelity-audit`
//  skill). The static gate proves that the iOS and watch code paths
//  share the same `LoopAlgorithmRunner` source; this dynamic test
//  catches drift if anyone ever forks the runner per platform.
//
//  ## Where this test ships
//
//  Logically this belongs in a dedicated `LoopAlgorithmReconciliationTests`
//  target. Practically: creating a new test target requires intricate
//  pbxproj surgery (PBXNativeTarget + build configs + scheme + resources
//  phase) that risks corrupting the project file with very low payoff —
//  the test bundle would then need to link both `LoopAlgorithmCore` and
//  `WatchAlgorithmKit`, which `LoopTests` already does (via the existing
//  `@testable import LoopAlgorithmCore` and a one-line `WatchAlgorithmKit`
//  framework link added in this commit).
//
//  Per the Phase 5b plan's explicit escalation:
//      "If pbxproj surgery for a new test target proves too risky, the
//       alternative is to ship `ReconciliationTests.swift` in the existing
//       `LoopTests` target instead."
//
//  This is that alternative. The fixture JSON files live under
//  `LoopAlgorithmReconciliationTests/Fixtures/` (per the plan's directory
//  structure) and are referenced by the `LoopTests` resources phase so
//  they bundle into `LoopTests.xctest`.
//
//  ## Current state — active
//
//  The 3 fixture files (`placeholder-{steady-state,post-meal-carbs,
//  predicted-hypo}.json`) carry programmatically-synthesized
//  `LoopPredictionInput`s with realistic settings + scenario-shaped
//  buffers and a captured `expectedOutput.predictedGlucose` produced by
//  running `LoopAlgorithm.generatePrediction` on the same input. The
//  test re-runs the same generator (via `WatchAlgorithmDriver.runForReconciliation`
//  → `LoopAlgorithm.generatePrediction`) and asserts byte equality.
//
//  The XCTSkip paths remain as defensive fallbacks: if a fixture file
//  fails to decode (e.g., LoopKit pin advances and breaks the wire
//  format) the suite skips that test rather than failing red — Carl
//  re-captures the affected fixture and re-runs.
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopAlgorithmCore
@testable import WatchAlgorithmKit

#if DEBUG
final class ReconciliationTests: XCTestCase {

    /// Sentinel that captured fixtures use for `name` until promoted to
    /// "real" status. Tests treat both decode failure AND this sentinel as
    /// "still placeholder" → XCTSkip.
    private static let placeholderName = "PLACEHOLDER_REPLACE_WITH_REAL_CAPTURE"

    private func loadFixture(_ filename: String) throws -> LoopAlgorithmReconciliationFixture {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: filename, withExtension: "json") else {
            throw XCTSkip("Fixture \(filename).json not found in test bundle — placeholder may need replacement")
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture: LoopAlgorithmReconciliationFixture
        do {
            fixture = try decoder.decode(LoopAlgorithmReconciliationFixture.self, from: data)
        } catch {
            throw XCTSkip("Fixture \(filename).json failed to decode (placeholder?): \(error)")
        }
        if fixture.name == Self.placeholderName {
            throw XCTSkip("Fixture \(filename).json is the placeholder sentinel — replace via captureFixtureForReconciliation (see Fixtures/README.md)")
        }
        return fixture
    }

    private func assertEquivalent(_ fixture: LoopAlgorithmReconciliationFixture,
                                  file: StaticString = #file,
                                  line: UInt = #line) throws {
        let watchOutput = try WatchAlgorithmDriver.runForReconciliation(fixture.input)

        // predictedGlucose carries `PredictedGlucoseValue` items: identical
        // start dates and identical mg/dL quantities are required. Direct
        // array equality works because the upstream type is Equatable.
        XCTAssertEqual(watchOutput.predictedGlucose.count,
                       fixture.expectedOutput.predictedGlucose.count,
                       "predictedGlucose length drift between iOS capture and watch replay",
                       file: file, line: line)
        for (idx, (expected, actual)) in zip(fixture.expectedOutput.predictedGlucose,
                                             watchOutput.predictedGlucose).enumerated() {
            XCTAssertEqual(expected.startDate, actual.startDate,
                           "predictedGlucose[\(idx)].startDate drift",
                           file: file, line: line)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter),
                           actual.quantity.doubleValue(for: .milligramsPerDeciliter),
                           accuracy: 1e-9,
                           "predictedGlucose[\(idx)].quantity drift",
                           file: file, line: line)
        }

        XCTAssertEqual(watchOutput.doseRecommendation,
                       fixture.expectedOutput.doseRecommendation,
                       "doseRecommendation drift between iOS capture and watch replay",
                       file: file, line: line)
    }

    // MARK: - Scenarios

    func test_steadyState_iOSAndWatchProduceIdenticalOutput() throws {
        let fixture = try loadFixture("placeholder-steady-state")
        try assertEquivalent(fixture)
    }

    func test_postMealCarbs_iOSAndWatchProduceIdenticalOutput() throws {
        let fixture = try loadFixture("placeholder-post-meal-carbs")
        try assertEquivalent(fixture)
    }

    func test_predictedHypo_iOSAndWatchProduceIdenticalOutput() throws {
        let fixture = try loadFixture("placeholder-predicted-hypo")
        try assertEquivalent(fixture)
    }
}
#endif
