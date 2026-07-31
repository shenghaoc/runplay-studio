# Tasks: Remaining Core Hotspot Profile

## Phase 1: Foundation

- [x] Read all production source files and understand computational characteristics
- [x] Create profiling harness skeleton (`RemainingCoreHotspotProfile.swift`)
- [x] Create runner script (`run-remaining-core-hotspot-profile.sh`)
- [x] Create synthetic fixture generators for all families
- [x] Split support into `Profiling/` helpers (timing, fixtures, digests, FIT builder)
- [x] Remove `testAllFamilies` double-execution path; add invocation counters
- [x] Use `ContinuousClock` + warm-up/measured iteration statistics

## Phase 2: Analysis Profiling (Family A)

- [x] Implement A1–A7 synthetic fixtures (behavioral matrix, not generic straight lines only)
- [x] Implement Mode A: `WorkoutAnalyzer.analyze` / `normalizeAndAnalyze` timing
- [x] Implement Mode B: shared production path with internal phase timings
- [x] Exact workout digests (parity)
- [x] Run and collect results (including product-limit A7)
- [x] Validate accounting ≤5%

## Phase 3: Alignment Profiling (Family B)

- [x] Implement B1–B5 synthetic fixtures
- [x] Implement Mode A: `ConstrainedDynamicTimeWarpingAligner.align` timing
- [x] Implement Mode B: sample-builder + direction + native DTW + blocks/diagnostics
- [x] Aligned metrics service probe
- [x] Run and collect results
- [x] Validate accounting ≤5%

## Phase 4: Route Metrics Profiling (Family C)

- [x] Implement C1–C5 synthetic fixtures
- [x] Implement Mode A/B for `RouteMetricProfileBuilder`
- [x] Platform `RouteMetricMapLineBuilder` coalescing profile
- [x] Studio cache / replay non-rebuild coverage via existing ViewModel tests
- [x] Run and collect results (including product-limit C5 when enabled)
- [x] Validate accounting ≤5%

## Phase 5: Import Profiling (Family D)

- [x] JSON / GPX / TCX / FIT D1–D6-style fixtures
- [x] Multi-session FIT parse + single-importer rejection evidence
- [x] Strava archive scan/import via Platform harness
- [x] Import parity digests excluding minted UUIDs
- [x] Run and collect results

## Phase 6: Comparison/Service Profiling (Family E)

- [x] `WorkoutComparisonService` fixtures
- [x] `RouteAlignmentMetricsService` probe (with Family B)
- [x] `WorkoutLibraryQueryService` scaling (1k / 10k; 50k under product-limit mode)
- [x] Run and collect results

## Phase 7: Analysis and Roadmap

- [x] Score candidates on the eleven-dimension rubric
- [x] Identify disqualifiers
- [x] Apply selection thresholds against ordinary + large + product-limit evidence
- [x] Select next implementation phase: **SegmentDetector**
- [x] Produce bounded remaining roadmap (min 2 / expected 4 / max 5)
- [x] Document rejected migrations with rationale

## Phase 8: Documentation

- [x] Update `docs/phase-plan.md`
- [x] Update `docs/architecture.md`
- [x] README engine ownership summary still accurate (no change required)

## Phase 9: PR

- [x] Supersede PR 92
- [x] Open/update draft PR with complete results, tables, and roadmap
- [x] Boundary validation extended for hotspot profiling APIs
- [x] Run full verification suite (boundaries, AST, native, ASan/UBSan, Core/Platform/Studio, package-consumer, release profile families)
- [x] Confirm production behavior unchanged / mark ready for review
