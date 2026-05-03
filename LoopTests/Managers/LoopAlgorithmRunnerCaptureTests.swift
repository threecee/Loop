//
//  LoopAlgorithmRunnerCaptureTests.swift
//  LoopTests
//
//  B.8.4 Phase 5a sanity tests for the DEBUG-only fixture-capture
//  instrumentation introduced alongside `LoopAlgorithmRunner`. Verifies:
//
//   - `CapturedAlgorithmInput` Codable round-trips correctly.
//   - `CapturedAlgorithmOutput` Codable round-trips correctly.
//   - `LoopAlgorithmReconciliationFixture` Codable round-trips correctly.
//
//  The "real" exercise of this surface is Carl's manual LLDB capture during
//  on-device iterations matching the 3 reconciliation scenarios; the unit
//  test below confirms the JSON wiring (Codable) is sound. The runner-side
//  `captureFixtureForReconciliation(name:)` -> file-write path is exercised
//  in Phase 5b's reconciliation target where the full mock-store harness
//  needed to construct a runner is already in place.
//

#if DEBUG

import XCTest
import HealthKit
import LoopKit
@testable import LoopAlgorithmCore

final class LoopAlgorithmRunnerCaptureTests: XCTestCase {

    private let fixtureName = "test-sanity-phase5a"

    override func tearDown() {
        super.tearDown()
        let url = URL(fileURLWithPath: "/tmp/loop-reconciliation-\(fixtureName).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - CapturedAlgorithmInput round-trip

    func test_capturedAlgorithmInput_codable_roundTrip() throws {
        let predictionDate = Date(timeIntervalSince1970: 1_700_000_000)
        let input = CapturedAlgorithmInput(
            predictionInput: makePredictionInput(),
            predictionDate: predictionDate,
            doseRecommendationType: .automaticBolus
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(input)
        XCTAssertGreaterThan(data.count, 0)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CapturedAlgorithmInput.self, from: data)
        XCTAssertEqual(decoded.doseRecommendationType, "automaticBolus")
        XCTAssertEqual(decoded.predictionDate, predictionDate)
        XCTAssertEqual(decoded.predictionInput.glucoseHistory.count,
                       input.predictionInput.glucoseHistory.count)
    }

    // MARK: - CapturedAlgorithmOutput round-trip

    func test_capturedAlgorithmOutput_codable_roundTrip() throws {
        let output = CapturedAlgorithmOutput(
            predictedGlucose: [],
            doseRecommendation: AutomaticDoseRecommendation(basalAdjustment: nil)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(output)
        XCTAssertGreaterThan(data.count, 0)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CapturedAlgorithmOutput.self, from: data)
        XCTAssertEqual(decoded.predictedGlucose.count, output.predictedGlucose.count)
        XCTAssertEqual(decoded.doseRecommendation.basalAdjustment,
                       output.doseRecommendation.basalAdjustment)
    }

    // MARK: - LoopAlgorithmReconciliationFixture round-trip

    func test_reconciliationFixture_codable_roundTrip() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = LoopAlgorithmReconciliationFixture(
            name: fixtureName,
            capturedAt: capturedAt,
            input: CapturedAlgorithmInput(
                predictionInput: makePredictionInput(),
                predictionDate: capturedAt,
                doseRecommendationType: .tempBasal
            ),
            expectedOutput: CapturedAlgorithmOutput(
                predictedGlucose: [],
                doseRecommendation: AutomaticDoseRecommendation(basalAdjustment: nil)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fixture)
        XCTAssertGreaterThan(data.count, 0)

        // Sanity check: writing to /tmp like the production capture path does.
        let url = URL(fileURLWithPath: "/tmp/loop-reconciliation-\(fixtureName).json")
        try data.write(to: url, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let loaded = try Data(contentsOf: url)
        XCTAssertEqual(loaded.count, data.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LoopAlgorithmReconciliationFixture.self, from: loaded)
        XCTAssertEqual(decoded.name, fixtureName)
        XCTAssertEqual(decoded.capturedAt, capturedAt)
        XCTAssertEqual(decoded.input.doseRecommendationType, "tempBasal")
    }

    // MARK: - Helpers

    private func makePredictionInput() -> LoopPredictionInput {
        return LoopPredictionInput(
            glucoseHistory: [],
            doses: [],
            carbEntries: [],
            settings: LoopAlgorithmSettings(
                basal: [],
                sensitivity: [],
                carbRatio: [],
                target: []
            )
        )
    }
}

#endif
