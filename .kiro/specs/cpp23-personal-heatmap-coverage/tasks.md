# Personal Heatmap Route Coverage C++23 Migration Tasks

- [x] 1. C++23 Engine Kernel Implementation
  - [x] 1.1 Add `PersonalHeatmapCoverage.hpp` to `RunPlayEngineCpp/include/RunPlayEngineCpp/` and include in `RunPlayEngine.hpp`.
  - [x] 1.2 Implement internal Web Mercator projection and grid traversal in `RunPlayEngineCpp/Sources/PersonalHeatmapCoverage.cpp` and `RunPlayEngineCpp/Sources/Internal/PersonalHeatmapProjectionInternal.hpp`.
  - [x] 1.3 Implement `compute_personal_heatmap_workout_coverage` function and static assertions.
  - [x] 1.4 Add C++ native unit tests in `RunPlayEngineCpp/Tests/PersonalHeatmapCoverageTests.cpp` covering empty, null, boundary, projection, segment gaps, traversal, and output ordering.

- [x] 2. Swift Interop & Parity Bridge Implementation
  - [x] 2.1 Implement `RunPlayPersonalHeatmapCoverageBridge.swift` in `RunPlayCore/Sources/Interop/`.
  - [x] 2.2 Add unit and parity tests in `RunPlayPersonalHeatmapCoverageBridgeTests.swift` comparing Swift reference output against C++ bridge output.
  - [x] 2.3 Add `SwiftPersonalHeatmapBuilderOracle.swift` to `RunPlayCoreTests` for end-to-end parity validation, and assert whole-`PersonalHeatmapSnapshot` equality against the shipping builder in `PersonalHeatmapBuilderOracleParityTests.swift`.
  - [x] 2.4 Add 1,000 deterministic generated test fixtures.

- [x] 3. PersonalHeatmapBuilder Refactor
  - [x] 3.1 Update `PersonalHeatmapBuilder.swift` to use cached `RunPlayPersonalHeatmapPreparedBatch` and invoke C++ bridge for per-workout coverage.
  - [x] 3.2 Preserve Swift date filtering, global count aggregation, adaptive resolution, bounds, statistics, diagnostics, and cancellation.
  - [x] 3.3 Ensure existing tests in `PersonalHeatmapBuilderTests`, `PersonalHeatmapViewModelTests`, and `RouteMapDataTests` pass.

- [x] 4. Benchmarking, Validation & Documentation
  - [x] 4.1 Add `PersonalHeatmapCoverageBenchmark.swift` and `scripts/run-personal-heatmap-benchmark.sh`.
  - [x] 4.2 Update `scripts/validate-cpp-public-ast.py` to validate `compute_personal_heatmap_workout_coverage` AST and update self-test.
  - [x] 4.3 Update `scripts/validate-cpp-boundaries.sh` to enforce boundary rules for heatmap coverage bridge.
  - [x] 4.4 Run full verification suite (ASan/UBSan, Linux, macOS, SwiftPM, package consumer, AST, boundaries, benchmarks).
  - [x] 4.5 Update documentation:
    - `AGENTS.md` — engine exposure list, heatmap Swift/C++ ownership split, and approved pointer boundaries including the capacity-negotiated output contract.
    - `docs/architecture.md` — engine exposure list, pointer boundaries, migrated-vs-Swift ownership, and the Personal Heatmap layer table.
    - `README.md` — engine exposure list in Core Testability.
    - `docs/phase-plan.md` — C++23 migration checklist split into the completed per-workout coverage cutover and the still-open projection/comparison/cross-workout aggregation work.

## Notes

- The personal heatmap coverage boundary is the first capacity-negotiated
  boundary in the engine. Unlike the per-sample boundaries it does not write
  `sample_count` entries; its output is a de-duplicated cell set sized by
  `required_cell_count`, and it writes nothing on
  `insufficient_output_capacity` so Swift can reallocate and retry.
  `AGENTS.md` and `docs/architecture.md` previously stated the per-sample write
  contract as a global rule; both now state the distinction explicitly.
- `PersonalHeatmapProjection` and `PersonalHeatmapGridTraversal` intentionally
  remain public Swift per requirement 5.1. They are no longer on the production
  coverage path — the builder reads only
  `PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval` — and now serve
  as the reference implementation backing both parity oracles.
- Requirement 4.2 (native call under 500 ms for 1,000,000 route points) is
  measured by the opt-in benchmark, not asserted in CI. This matches the
  existing convention for the route-quality and step-distance migrations, whose
  benchmarks are likewise gated behind `RUNPLAY_BENCHMARK=1`.
