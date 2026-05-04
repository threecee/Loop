//
//  PredictionInputEffectTests.swift
//  LoopTests
//
//  B.8.5: invariant tests for the canonical `PredictionInputEffect.allEnabled`
//  static-let. Documents the post-cleanup invariant that both
//  `LoopSettings.enabledEffects` (iOS) and
//  `LoopSettings.loopAlgorithmCore_enabledEffects` (LoopAlgorithmCore)
//  delegate to the same constant. Future drift between the two extensions
//  surfaces here.
//

import XCTest
@testable import LoopAlgorithmCore
import LoopCore
@testable import Loop

final class PredictionInputEffectTests: XCTestCase {

    /// The canonical constant equals `.all` (the existing static-let). Future
    /// changes to either must be intentional — both extensions delegate here.
    func test_allEnabled_equalsAll() {
        XCTAssertEqual(PredictionInputEffect.allEnabled, PredictionInputEffect.all)
    }

    /// `LoopConstants.retrospectiveCorrectionEnabled` is hard-coded `true`
    /// today. The iOS `enabledEffects` extension thus delegates to
    /// `allEnabled` directly. If the toggle becomes user-configurable, the
    /// guard branch becomes load-bearing — this test will need a fixture
    /// that flips the constant.
    func test_LoopSettings_enabledEffects_matchesAllEnabled() {
        let settings = LoopSettings()
        XCTAssertEqual(settings.enabledEffects, PredictionInputEffect.allEnabled)
    }

    /// The LoopAlgorithmCore-side mirror always delegates to `allEnabled`
    /// (no constant gating — LoopAlgorithmCore doesn't know about
    /// `LoopConstants`). Drift between iOS + LoopAlgorithmCore extensions
    /// surfaces here.
    func test_loopAlgorithmCore_enabledEffects_matchesAllEnabled() {
        let settings = LoopSettings()
        XCTAssertEqual(settings.loopAlgorithmCore_enabledEffects, PredictionInputEffect.allEnabled)
    }
}
