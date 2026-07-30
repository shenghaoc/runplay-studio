# Swift Personal Heatmap Aggregation Optimization Tasks

Checked boxes do not prove completion. Tests, complete-builder measurements,
profile accounting, CI, and exact-head review are the evidence.

- [x] 1. Preserve the phase contract
  - [x] 1.1 Confirm live `origin/main`, merged prerequisite PRs, no overlapping PR, and a dedicated branch/worktree.
  - [x] 1.2 Capture three release benchmark and profile baselines outside the repository.
  - [x] 1.3 Run inherited boundary, native, sanitizer, Core, consumer, SwiftPM, and Xcode baselines.

- [x] 2. Optimize `PersonalHeatmapCellID`
  - [x] 2.1 Mix both signed coordinates into one wrapping 64-bit word and call `Hasher.combine` once.
  - [x] 2.2 Preserve equality, Y-then-X comparison, Codable, and geographic semantics.
  - [x] 2.3 Add extreme-coordinate, Codable, ordering, 100,000-key, and repeated-update tests.

- [x] 3. Add bounded aggregation capacity hints
  - [x] 3.1 Implement overflow-safe rendered-budget, capped route-point, initial-pass, and later-pass policies.
  - [x] 3.2 Reserve the global counts dictionary before every adaptive pass.
  - [x] 3.3 Prove hint bounds, odd rounding, overflow safety, cap behaviour, and output invariance.

- [x] 4. Accumulate directly from native output
  - [x] 4.1 Add pure-Swift coverage metadata.
  - [x] 4.2 Refactor allocation, capacity retry, native invocation, status mapping, validation, and hint updates behind one private nonescaping output-buffer helper.
  - [x] 4.3 Preserve array-returning coverage for tests.
  - [x] 4.4 Add production `accumulateCoverage(...into:)` with 2,048-cell cancellation checks and no cell array.
  - [x] 4.5 Add test-only profiled direct accumulation sharing the production implementation.

- [x] 5. Cut over production safely
  - [x] 5.1 Make `PersonalHeatmapBuilder` call direct accumulation and consume returned metadata.
  - [x] 5.2 Preserve one native operation per workout/pass and the existing exact-capacity retry only.
  - [x] 5.3 Prove cancellation discards partial local counts and publishes no snapshot.

- [x] 6. Expand correctness coverage
  - [x] 6.1 Compare array coverage and accumulation metadata/counts across the full bridge fixture matrix.
  - [x] 6.2 Verify double accumulation reaches count two and capacity retries/cache reuse remain correct.
  - [x] 6.3 Add at least 1,000 deterministic generated complete-snapshot parity fixtures varying library and configuration shape.
  - [x] 6.4 Preserve existing builder, oracle, and Studio view-model tests.

- [x] 7. Update diagnostics and mechanical boundaries
  - [x] 7.1 Update the production-equivalent pipeline profile for direct consumption/counting.
  - [x] 7.2 Add the skipped same-binary aggregation microbenchmark with five warm-ups and twenty measured iterations.
  - [x] 7.3 Enforce builder cutover, test-only profiling, Interop pointer containment, and unchanged native API mechanically.

- [x] 8. Update durable documentation
  - [x] 8.1 Document Swift aggregation ownership, direct caller-owned-buffer consumption, pointer lifetime, bounded reservation hints, and unchanged identity/persistence.
  - [x] 8.2 Mark this bounded phase complete and record profiling active hotspots as the next decision point.

- [x] 9. Verify and publish
  - [x] 9.1 Run every focused, Core, Platform, Studio, full SwiftPM, Xcode, native, sanitizer, AST, boundary, and consumer gate.
  - [x] 9.2 Run three final release benchmarks and profiles, compare every production-shaped fixture and memory against baseline, and report any missed target honestly.
  - [x] 9.3 Commit, push, update the draft PR evidence, and reconcile exact remote head, review threads, CI, and mergeability without merging.
