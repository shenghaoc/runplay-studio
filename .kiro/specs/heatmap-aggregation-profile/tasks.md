# Personal Heatmap Aggregation Profiling Tasks

Checked boxes do not prove completion. Benchmark evidence, tests, and CI do.

- [x] 1. Profiling harness
  - [x] 1.1 Add `RunPlayCore/Tests/RunPlayCoreTests/PersonalHeatmapPipelineProfile.swift`, skipped unless `RUNPLAY_HEATMAP_PROFILE=1`.
  - [x] 1.2 Time Mode A: the unmodified public `PersonalHeatmapBuilder.build`, with no timing hooks added to production code.
  - [x] 1.3 Implement Mode B: a test-only reconstruction of the production orchestration that prepares exactly one native batch and records phase timings.
  - [x] 1.4 Assert every Mode B snapshot exactly equal to both `PersonalHeatmapBuilder` and `SwiftPersonalHeatmapBuilderOracle`.
  - [x] 1.5 Report Mode B / Mode A overhead so phase percentages can be read honestly.

- [x] 2. Phase decomposition
  - [x] 2.1 Time date filtering, native preparation, coverage bridge, cross-workout counting, minimum-repeat filtering, adaptive decision, sorting, cell materialization, and snapshot assembly separately.
  - [x] 2.2 Retain one row per adaptive-resolution pass rather than reporting only the final effective resolution.
  - [x] 2.3 Report the sum of measured phases against the profiled wall clock with the unaccounted difference and its percentage.

- [x] 3. Internal coverage diagnostic
  - [x] 3.1 Add `RunPlayPersonalHeatmapCoverageProfile` (pure Swift, no imported C++ type) and `profiledCoverage(...)` to `RunPlayPersonalHeatmapCoverageBridge.swift`.
  - [x] 3.2 Route production `coverage(...)` and `profiledCoverage(...)` through one shared implementation; do not create a second boundary implementation.
  - [x] 3.3 Read no clock on production calls; use `ContinuousClock` so `RunPlayCore` stays Linux-valid.
  - [x] 3.4 Separate native C++ execution, output allocation, capacity retries, and C++-to-Swift cell translation.

- [x] 4. Fixture matrix
  - [x] 4.1 Implement fixtures A–H with deterministic synthetic libraries and no private data.
  - [x] 4.2 Exercise multiple source segments, invalid coordinates, oversized rasterized intervals, and rejected over-ceiling intervals.
  - [x] 4.3 Use 5 warm-ups + 20 measured iterations for the primary fixture and 3 + 10 for the rest; report median, minimum, p90, and maximum for the primary.
  - [x] 4.4 Record resident memory on macOS behind `#if canImport(Darwin)` without asserting it.

- [x] 5. Runner and existing benchmark correction
  - [x] 5.1 Add `scripts/run-personal-heatmap-profile.sh`: release mode, environment variable set, only the profiling test, Markdown report, nonzero exit on parity or validation failure.
  - [x] 5.2 Stop `PersonalHeatmapCoverageBenchmark` from timing a duplicate preparation and a duplicate coverage sweep inside its gated production measurement.
  - [x] 5.3 Relabel the remaining subtimings as independent diagnostics and point at the profile script for additive attribution; preserve the merge-gate comparison.

- [x] 6. Boundary validation
  - [x] 6.1 Enforce that the profiling API is named only by its declaring bridge and by tests, and never by `PersonalHeatmapBuilder`.
  - [x] 6.2 Enforce that the diagnostic stays internal and that the public heatmap declarations are unchanged.
  - [x] 6.3 Enforce that the harness self-skips without `RUNPLAY_HEATMAP_PROFILE=1`.
  - [x] 6.4 Enforce that production Swift sources carry no signposts and do not import `os` / `OSLog`.
  - [x] 6.5 Give each new matcher adversarial positive and negative fixtures, and verify each new check fails on an injected violation.

- [x] 7. Verification
  - [x] 7.1 Boundary script, public C++ AST self-test, native C++ tests, ASan + UBSan.
  - [x] 7.2 `PersonalHeatmapBuilderTests`, `RunPlayPersonalHeatmapCoverageBridgeTests`, `PersonalHeatmapBuilderOracleParityTests`, `RunPlayCoreTests`, `PersonalHeatmapViewModelTests`.
  - [x] 7.3 Package consumer smoke build, full macOS `swift test`, `xcodebuild test`.
  - [x] 7.4 Heatmap benchmark and heatmap profile, with the profile reproduced across repeated release runs.
  - [x] 7.5 One local Time Profiler trace, exported and aggregated by execution path, to validate the ranking independently. No `.trace` bundle committed.

- [x] 8. Architecture decision
  - [x] 8.1 Answer the candidate-boundary feasibility questions for a native cross-workout aggregation boundary.
  - [x] 8.2 Select exactly one decision and record the rejected alternatives.
  - [x] 8.3 Update `docs/phase-plan.md` and `docs/architecture.md`; keep machine-specific timings out of general documentation.

## Decision note

**Selected: optimize the remaining Swift implementation. Do not migrate
cross-workout aggregation to C++ in the next phase.**

Measured shares of the profiled wall clock, consistent across repeated release
runs and corroborated by an independent Time Profiler trace of the production
path only:

- The already-native coverage bridge is the dominant cost in every
  production-reachable configuration — roughly 54–74%, almost all of it inside
  the C++ kernel.
- Cross-workout counting is the largest remaining Swift cost, roughly 9–29%,
  and its cost is Swift `Hasher` plus dictionary growth rather than algorithmic
  work.
- C++-to-Swift cell translation is 0.4–2.5% and output allocation including
  every capacity retry is at most 1.3%, so reducing coverage-output translation
  cannot pay for a new boundary.
- Minimum-repeat filtering is at most 2.2%.
- Sorting and cell materialization are large only when the rendered-cell budget
  is lifted far above the shipping default. The shipping UI always requests
  `PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount`, so the
  adaptive loop bounds both phases to that budget; in the equivalent
  production-reachable fixture they are single-digit percentages.

A native aggregation boundary was rejected on feasibility, not on payoff. There
is no library-wide route-point limit — only a per-workout one — so a whole-pass
native call would need a new arbitrary whole-library limit and would run
uninterruptibly across the entire library. Keeping the call per-workout instead
would require either a retained native accumulator, which contradicts the
engine's "C++ retains nothing" contract, or a Swift-owned open-addressed table
plus a rehash boundary, which is materially more complex than the Swift fixes
that address the same measured cost.
