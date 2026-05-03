# Reconciliation Test Fixtures

These placeholder JSON files (`{}`) exist only to document the expected
location of real captures. They will fail to decode as
`LoopAlgorithmReconciliationFixture`; the test methods in
`ReconciliationTests.swift` catch the decode error and convert it to
`XCTSkip`, so the overall test suite stays green until real fixtures are
recorded.

## Replacement procedure

Phase 5a (commit `782a5807`) shipped a DEBUG-only LLDB helper on the iOS
runner. To replace one of the placeholders with a real capture:

1. Run a DEBUG build of Loop in the iOS simulator. Drive the Loop into
   one of the three target shapes:
     - `steady-state`        — flat in-range glucose, no recent carbs.
     - `post-meal-carbs`     — glucose rising from a recent meal entry.
     - `predicted-hypo`      — predicted glucose dropping toward / below
                                the suspend threshold.
2. After the algorithm has emitted a recommendation for that iteration,
   pause in the Xcode debugger and call (LLDB):

   ```
   (lldb) expr (LoopAppManager.shared.loopDataManager.runner as! LoopAlgorithmRunner).captureFixtureForReconciliation(name: "steady-state")
   ```

   The runner serializes its `lastInput` + `lastOutput` to
   `/tmp/loop-reconciliation-<name>.json`.
3. Copy the file into this directory and rename to drop the
   `placeholder-` prefix is **not** what you want — the tests load
   `placeholder-steady-state.json`, etc., so overwrite the placeholder
   in place:

   ```
   cp /tmp/loop-reconciliation-steady-state.json \
      LoopAlgorithmReconciliationTests/Fixtures/placeholder-steady-state.json
   ```

   (The filename can stay as-is. The test recognizes a real fixture by
   the fact that decode succeeds and `name !=
   "PLACEHOLDER_REPLACE_WITH_REAL_CAPTURE"`.)
4. Re-run the reconciliation tests:

   ```
   xcodebuild test -workspace LoopWorkspace.xcworkspace \
       -scheme LoopWorkspace \
       -destination 'platform=iOS Simulator,name=iPhone 17' \
       -only-testing:LoopTests/ReconciliationTests
   ```

   The placeholder-skipping branch gives way to actual byte-equality
   checks between iOS and watch runners on the captured input.

## Why these placeholders are valid `{}`

A reconciliation test target needs to *exist* before any real capture is
possible; it has no value if it depends on data that hasn't been
collected yet. Empty JSON object decodes deterministically as a decode
failure, which the tests catch and convert to `XCTSkip`. This keeps the
test target green and the harness exercised on every CI run.
