# Personal Heatmap Aggregation Profiling Design

## Why the previous breakdown was not usable

`PersonalHeatmapCoverageBenchmark` established the authoritative comparison —
complete production builder against complete Swift builder oracle — and that
comparison remains the merge gate. Its two extra subtimings, however, could not
be added to explain the production total:

- input conversion was timed on a batch prepared separately from the one
  `PersonalHeatmapBuilder.build` prepares internally, so the same conversion was
  paid twice and attributed once;
- the native coverage total was timed once at the **final** effective cell size,
  while the builder performs one coverage sweep per adaptive pass;
- both diagnostics were executed inside the block that timed the "production
  builder", so the gated number silently included a duplicate preparation and a
  duplicate coverage sweep;
- adaptive-pass coverage and output translation inside the measured build were
  never isolated.

This phase replaces that breakdown with an additive decomposition taken from one
production-equivalent orchestration, and corrects the benchmark's labelling and
its gated measurement.

## Two-mode measurement

```text
Mode A  (authoritative)
    PersonalHeatmapBuilder().build(workouts:configuration:isCancelled:)
    unmodified public entry point, no timing hooks, no logging

Mode B  (diagnostic)
    PersonalHeatmapPipelineProfile.profiledBuild(...)
    test-only reconstruction of the same orchestration, phase-timed,
    asserted exactly equal to Mode A and to SwiftPersonalHeatmapBuilderOracle
```

Mode B exists because the phases worth timing live in `private` members of
`PersonalHeatmapBuilder`, which `@testable import` does not expose. Fidelity is
guaranteed by whole-snapshot equality against both the production builder and
the pre-migration Swift oracle rather than by inspection.

Mode B's own cost is calibrated by reporting the Mode B / Mode A median ratio.
Mode B's total is never used as a product benchmark.

## Reconstructed orchestration

```text
profiledBuild
    ├── configuration validation
    ├── PHASE date filtering            trustworthy date, range filter, undated count
    ├── PHASE native preparation        RunPlayPersonalHeatmapCoverageBridge.prepare
    │                                   exactly one batch, reused by every pass
    ├── adaptive resolution loop, one row per pass
    │     ├── per workout
    │     │     ├── PHASE coverage bridge      preparedBatch.profiledCoverage
    │     │     │     ├── output allocation
    │     │     │     ├── native C++ execution
    │     │     │     ├── capacity retry (allocation + native again)
    │     │     │     └── C++ → Swift cell translation
    │     │     └── PHASE cross-workout counting   counts[cell, default: 0] += 1
    │     ├── PHASE minimum-repeat filtering
    │     └── PHASE adaptive decision             budget check, then cellSize *= 2
    ├── PHASE deterministic sorting     filteredCounts.keys.sorted()
    ├── PHASE cell materialization      max overlap, cellBounds, log1p intensity,
    │                                   clamping, cells, aggregate bounds
    └── PHASE snapshot assembly         statistics, diagnostics, effective config
```

Top-level additive phases are date filtering, native preparation, coverage
bridge, cross-workout counting, minimum-repeat filtering, adaptive decision,
sorting, cell materialization, and snapshot assembly. Native execution, output
allocation, and cell translation are nested inside the coverage bridge and are
reported as *of which* rows, never summed again. Intra-pass loop overhead and
configuration validation fall outside every timed region and land in the
reported unaccounted residue. When that residue exceeds 5% of the profiled wall
clock for a fixture, the harness still reports Mode A/B medians, parity, and the
unaccounted percentage, but it suppresses that fixture's phase-attribution
tables and fails the fixture so an untrustworthy breakdown cannot be published.

## Internal coverage diagnostic

`RunPlayPersonalHeatmapPreparedBatch` gains one private implementation shared by
two entry points:

```text
coverage(...)          production, collectProfile: false, reads no clock
profiledCoverage(...)  test-only,  collectProfile: true
computeCoverage(..., collectProfile:)   the single implementation
```

The diagnostic result is pure Swift and exposes no imported C++ type:

```swift
struct RunPlayPersonalHeatmapCoverageProfile: Sendable {
    let requiredCellCount: Int
    let nativeCallCount: Int
    let capacityRetryCount: Int
    let outputAllocationNanoseconds: UInt64
    let nativeNanoseconds: UInt64
    let translationNanoseconds: UInt64
}
```

Timing uses `ContinuousClock` rather than `DispatchTime` so `RunPlayCore`
sources stay on the Swift standard library and remain valid on Linux. With
`collectProfile == false` no clock is read, so production calls pay one branch
per timed region and nothing else.

The public bridge result, the boundary signature, the C++ kernel, and the
capacity-negotiation contract are unchanged.

## Boundary validation

`scripts/validate-cpp-boundaries.sh` gains checks, each with adversarial
positive and negative fixtures, enforcing that:

- the profiling harness and its runner exist, and the runner is executable;
- the harness skips unless `RUNPLAY_HEATMAP_PROFILE=1`, so ordinary
  `swift test` in CI cannot run it;
- `profiledCoverage` and `RunPlayPersonalHeatmapCoverageProfile` are named only
  by the declaring bridge and by tests;
- `PersonalHeatmapBuilder` does not call the profiling API;
- the diagnostic stays internal rather than public or package;
- no production Swift source under `RunPlayCore`, `RunPlayPlatform`, or
  `RunPlayStudio` uses signposts or imports `os` / `OSLog`;
- the public personal heatmap declarations remain public in their documented
  locations.

Existing pointer, route-quality, heatmap, DTW, AST, Swift-import, and
package-graph checks are unchanged.

## Fixture matrix

Deterministic synthetic libraries, no private data, no `Date()`. Anomaly
positions are proportional to route length so every shape exercises the invalid
coordinate, oversized-interval, and rejected-over-ceiling-interval paths; at
1,000 points per workout they reduce to the historical benchmark's layout, so
the primary fixture stays comparable with it.

| Key | Shape | Purpose |
|---|---|---|
| A | 250 × 1,000, moderate overlap, fine cells, tight budget | primary representative adaptive build |
| B | 500 × 500, shared corridor | repeated global count increments against a small unique-cell set |
| C | 250 × 1,000, separated corridors | dictionary growth, filtering, sorting, bounds, materialization |
| D | 5,000 × 20 | per-workout bridge call, allocation, and loop overhead |
| E | 10 × 25,000 | native coverage and output translation with few calls |
| F | A's library, coarse cells, generous budget | one-pass aggregation without retry multiplication |
| G | A's library, fine cells, restrictive budget | repeated coarsening |
| H | A's library, `minimumWorkoutCount > 1` | large pre-filter dictionary against a small rendered result |

Libraries are cached by shape, so A, F, G, and H share one generated library and
differ only in configuration. The oversized-but-rasterized excursion is scaled
down for very short routes so a single teleport cannot dominate a 20-point
workout and hide the per-workout overhead fixture D exists to measure.

## Runner

`scripts/run-personal-heatmap-profile.sh` builds in release, sets
`RUNPLAY_HEATMAP_PROFILE=1`, runs only `PersonalHeatmapPipelineProfile`, prints
the Markdown report delimited by begin/end markers, and propagates the test exit
status so a parity or validation failure exits nonzero.

`scripts/run-personal-heatmap-benchmark.sh` remains the merge gate and now
points at the profile script for additive attribution.

## Decision framework

The phase concludes with exactly one decision. A native cross-workout
aggregation boundary is only approvable if it needs no arbitrary whole-library
workout or point limit and no uninterruptible whole-library operation without a
latency bound. Because the shipping UI always requests the default
5,000-rendered-cell budget, the adaptive loop structurally bounds sorting and
cell materialization; fixtures that lift that budget measure regimes production
cannot reach, and the decision weighs them accordingly.
