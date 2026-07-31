# Tasks: Remaining Core Hotspot Profile

## Phase 1: Foundation

- [ ] Read all production source files and understand computational characteristics
- [ ] Create profiling harness skeleton (`RemainingCoreHotspotProfile.swift`)
- [ ] Create runner script (`run-remaining-core-hotspot-profile.sh`)
- [ ] Create synthetic fixture generators for all families

## Phase 2: Analysis Profiling (Family A)

- [ ] Implement A1-A7 synthetic fixtures
- [ ] Implement Mode A: `WorkoutAnalyzer.normalizeAndAnalyze()` timing
- [ ] Implement Mode B: decomposed phase timing with parity assertion
- [ ] Run and collect results
- [ ] Validate accounting ≤5%

## Phase 3: Alignment Profiling (Family B)

- [ ] Implement B1-B5 synthetic fixtures
- [ ] Implement Mode A: `ConstrainedDynamicTimeWarpingAligner.align()` timing
- [ ] Implement Mode B: decomposed phase timing with parity assertion
- [ ] Run and collect results
- [ ] Validate accounting ≤5%

## Phase 4: Route Metrics Profiling (Family C)

- [ ] Implement C1-C5 synthetic fixtures
- [ ] Implement Mode A: production entrypoint timing
- [ ] Implement Mode B: decomposed phase timing with parity assertion
- [ ] Run and collect results
- [ ] Validate accounting ≤5%

## Phase 5: Import Profiling (Family D)

- [ ] Implement D1-D6 synthetic fixtures for JSON, GPX, TCX, FIT
- [ ] Implement per-importer decomposed timing (read, parse, points, timestamps, normalize, analyze)
- [ ] Run and collect results
- [ ] Validate accounting ≤5%

## Phase 6: Comparison/Service Profiling (Family E)

- [ ] Implement fixtures for WorkoutComparisonService, RouteAlignmentMetricsService
- [ ] Profile WorkoutLibraryQueryService computation
- [ ] Run and collect results

## Phase 7: Analysis and Roadmap

- [ ] Score all candidates on migration-value rubric (0-5 per dimension)
- [ ] Identify disqualifiers
- [ ] Apply selection thresholds
- [ ] Select next implementation phase
- [ ] Produce bounded remaining roadmap (min/expected/max phase counts)
- [ ] Document rejected migrations with rationale

## Phase 8: Documentation

- [ ] Update `docs/phase-plan.md`
- [ ] Update `docs/architecture.md` (if needed)
- [ ] Update `README.md` (if needed)

## Phase 9: PR

- [ ] Open draft PR with complete results, tables, and roadmap
- [ ] Run full verification suite
- [ ] Confirm production behavior unchanged
