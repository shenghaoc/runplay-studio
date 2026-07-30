# Swift Personal Heatmap Aggregation Optimization Tasks

Checked boxes do not prove completion. Tests, complete-builder measurements,
profile accounting, CI, and exact-head review are the evidence.

- [ ] 1. Preserve the phase contract
  - [ ] 1.1 Confirm live `origin/main`, merged prerequisite PRs, no overlapping PR, and a dedicated branch/worktree.
  - [ ] 1.2 Capture three release benchmark and profile baselines outside the repository.
  - [ ] 1.3 Run inherited boundary, native, sanitizer, Core, consumer, SwiftPM, and Xcode baselines.

- [ ] 2. Optimize `PersonalHeatmapCellID`
  - [ ] 2.1 Mix both signed coordinates into one wrapping 64-bit word and call `Hasher.combine` once.
  - [ ] 2.2 Preserve equality, Y-then-X comparison, Codable, and geographic semantics.
  - [ ] 2.3 Add extreme-coordinate, Codable, ordering, 100,000-key, and repeated-update tests.

- [ ] 3. Add bounded aggregation capacity hints
  - [ ] 3.1 Implement overflow-safe rendered-budget, capped route-point, initial-pass, and later-pass policies.
  - [ ] 3.2 Reserve the global counts dictionary before every adaptive pass.
  - [ ] 3.3 Prove hint bounds, odd rounding, overflow safety, cap behaviour, and output invariance.

- [ ] 4. Accumulate directly from native output
  - [ ] 4.1 Add pure-Swift coverage metadata.
  - [ ] 4.2 Refactor allocation, capacity retry, native invocation, status mapping, validation, and hint updates behind one private nonescaping output-buffer helper.
  - [ ] 4.3 Preserve array-returning coverage for tests.
  - [ ] 4.4 Add production `accumulateCoverage(...into:)` with 2,048-cell cancellation checks and no cell array.
  - [ ] 4.5 Add test-only profiled direct accumulation sharing the production implementation.

- [ ] 5. Cut over production safely
  - [ ] 5.1 Make `PersonalHeatmapBuilder` call direct accumulation and consume returned metadata.
  - [ ] 5.2 Preserve one native operation per workout/pass and the existing exact-capacity retry only.
  - [ ] 5.3 Prove cancellation discards partial local counts and publishes no snapshot.

- [ ] 6. Expand correctness coverage
  - [ ] 6.1 Compare array coverage and accumulation metadata/counts across the full bridge fixture matrix.
  - [ ] 6.2 Verify double accumulation reaches count two and capacity retries/cache reuse remain correct.
  - [ ] 6.3 Add at least 1,000 deterministic generated complete-snapshot parity fixtures varying library and configuration shape.
  - [ ] 6.4 Preserve existing builder, oracle, and Studio view-model tests.

- [ ] 7. Update diagnostics and mechanical boundaries
  - [ ] 7.1 Update the production-equivalent pipeline profile for direct consumption/counting.
  - [ ] 7.2 Add the skipped same-binary aggregation microbenchmark with five warm-ups and twenty measured iterations.
  - [ ] 7.3 Enforce builder cutover, test-only profiling, Interop pointer containment, and unchanged native API mechanically.

- [ ] 8. Update durable documentation
  - [ ] 8.1 Document Swift aggregation ownership, direct caller-owned-buffer consumption, pointer lifetime, bounded reservation hints, and unchanged identity/persistence.
  - [ ] 8.2 Mark this bounded phase complete and record profiling active hotspots as the next decision point.

- [ ] 9. Verify and publish
  - [ ] 9.1 Run every focused, Core, Platform, Studio, full SwiftPM, Xcode, native, sanitizer, AST, boundary, and consumer gate.
  - [ ] 9.2 Run three final release benchmarks and profiles, compare every production-shaped fixture and memory against baseline, and report any missed target honestly.
  - [ ] 9.3 Commit, push, update the draft PR evidence, and reconcile exact remote head, review threads, CI, and mergeability without merging.
