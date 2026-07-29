# Personal Heatmap Route Coverage C++23 Migration Tasks

- [ ] 1. C++23 Engine Kernel Implementation
  - [ ] 1.1 Add `PersonalHeatmapCoverage.hpp` to `RunPlayEngineCpp/include/RunPlayEngineCpp/` and include in `RunPlayEngine.hpp`.
  - [ ] 1.2 Implement internal Web Mercator projection and grid traversal in `RunPlayEngineCpp/Sources/PersonalHeatmapCoverage.cpp` and `RunPlayEngineCpp/Sources/Internal/PersonalHeatmapProjectionInternal.hpp`.
  - [ ] 1.3 Implement `compute_personal_heatmap_workout_coverage` function and static assertions.
  - [ ] 1.4 Add C++ native unit tests in `RunPlayEngineCpp/Tests/PersonalHeatmapCoverageTests.cpp` covering empty, null, boundary, projection, segment gaps, traversal, and output ordering.

- [ ] 2. Swift Interop & Parity Bridge Implementation
  - [ ] 2.1 Implement `RunPlayPersonalHeatmapCoverageBridge.swift` in `RunPlayCore/Sources/Interop/`.
  - [ ] 2.2 Add unit and parity tests in `RunPlayPersonalHeatmapCoverageBridgeTests.swift` comparing Swift reference output against C++ bridge output.
  - [ ] 2.3 Add `SwiftPersonalHeatmapBuilderOracle.swift` to `RunPlayCoreTests` for end-to-end parity validation.
  - [ ] 2.4 Add 1,000 deterministic generated test fixtures.

- [ ] 3. PersonalHeatmapBuilder Refactor
  - [ ] 3.1 Update `PersonalHeatmapBuilder.swift` to use cached `RunPlayPersonalHeatmapPreparedBatch` and invoke C++ bridge for per-workout coverage.
  - [ ] 3.2 Preserve Swift date filtering, global count aggregation, adaptive resolution, bounds, statistics, diagnostics, and cancellation.
  - [ ] 3.3 Ensure existing tests in `PersonalHeatmapBuilderTests`, `PersonalHeatmapViewModelTests`, and `RouteMapDataTests` pass.

- [ ] 4. Benchmarking, Validation & Documentation
  - [ ] 4.1 Add `PersonalHeatmapCoverageBenchmark.swift` and `scripts/run-personal-heatmap-benchmark.sh`.
  - [ ] 4.2 Update `scripts/validate-cpp-public-ast.py` to validate `compute_personal_heatmap_workout_coverage` AST and update self-test.
  - [ ] 4.3 Update `scripts/validate-cpp-boundaries.sh` to enforce boundary rules for heatmap coverage bridge.
  - [ ] 4.4 Run full verification suite (ASan/UBSan, Linux, macOS, SwiftPM, package consumer, AST, boundaries, benchmarks).
  - [ ] 4.5 Update documentation in `AGENTS.md`, `README.md`, `docs/architecture.md`, `docs/phase-plan.md`.
