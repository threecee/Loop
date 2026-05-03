# bin/replay

Holding directory for B.8.4 reconciliation fixtures captured via
`LoopAlgorithmRunner.captureFixtureForReconciliation(name:)` (added in
Phase 5a, commit `782a5807`). Captured files land in `/tmp/` by default;
copy the curated ones here for archival, then promote into
`LoopAlgorithmReconciliationTests/Fixtures/` to wire them into the
reconciliation test suite.

The directory is empty in the initial Phase 5b commit; Carl fills it
during real DEBUG simulator iterations.

See `LoopAlgorithmReconciliationTests/Fixtures/README.md` for the
end-to-end capture-and-promote procedure.
