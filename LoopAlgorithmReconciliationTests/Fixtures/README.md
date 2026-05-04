# Reconciliation Test Fixtures

These JSON files are programmatically-synthesized
`LoopAlgorithmReconciliationFixture` instances for the 3 scenario tests
in `LoopTests/Managers/ReconciliationTests.swift`. Each fixture carries:

- `input`: a `CapturedAlgorithmInput` wrapping a self-contained
  `LoopPredictionInput` (glucose / dose / carb buffers + algorithm
  settings).
- `expectedOutput`: the `[PredictedGlucoseValue]` that
  `LoopAlgorithm.generatePrediction` produced when the fixture was
  generated. The accompanying `doseRecommendation` is empty
  (`AutomaticDoseRecommendation(basalAdjustment: nil)`) — the static
  predictor doesn't compute one, so equivalence is asserted on the
  glucose forecast.

The test runs `WatchAlgorithmDriver.runForReconciliation(input)` (which
delegates to the same `LoopAlgorithm.generatePrediction`) and asserts
byte-equality against `expectedOutput`. Drift between iOS-captured and
watch-replayed output triggers a test failure.

## Scenarios

- `placeholder-steady-state.json` — flat ~100 mg/dL glucose, basal-only
  insulin, no carbs. Algorithm predicts a near-flat forecast.
- `placeholder-post-meal-carbs.json` — gently rising glucose, recent
  30 g carb entry 30 min ago, basal-only insulin. Algorithm predicts a
  carb-effect-shaped curve.
- `placeholder-predicted-hypo.json` — glucose trending down (130 → 80),
  recent 2 U bolus 1 h ago, no carbs. Algorithm predicts dipping below
  the suspend threshold.

The filenames keep the `placeholder-` prefix for backward compatibility
with `ReconciliationTests.swift`'s resource lookups; the JSON content is
no longer placeholder.

## Regenerating fixtures

If LoopKit's wire format ever changes (e.g., a `LoopPredictionInput`
field is added/removed), regenerate via:

```
xcodebuild test -workspace LoopWorkspace.xcworkspace \
    -scheme LoopWorkspace \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:LoopTests/ReconciliationFixtureGenerator/test_generateAllFixtures \
    GENERATE_RECONCILIATION_FIXTURES=1
```

Then copy from the iOS simulator's bridged `/tmp` (which appears as the
host's `/private/tmp` for the simulator's host-tools paths):

```
cp /tmp/loop-reconciliation-steady-state.json \
   LoopAlgorithmReconciliationTests/Fixtures/placeholder-steady-state.json
cp /tmp/loop-reconciliation-post-meal-carbs.json \
   LoopAlgorithmReconciliationTests/Fixtures/placeholder-post-meal-carbs.json
cp /tmp/loop-reconciliation-predicted-hypo.json \
   LoopAlgorithmReconciliationTests/Fixtures/placeholder-predicted-hypo.json
```

The generator is gated `#if DEBUG` and `XCTSkipUnless` on
`GENERATE_RECONCILIATION_FIXTURES=1`, so it stays out of routine CI
runs.
