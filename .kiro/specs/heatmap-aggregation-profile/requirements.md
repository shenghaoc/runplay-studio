# Personal Heatmap Aggregation Profiling Requirements

This is a **profiling and architecture-decision phase**, not a production
migration. No production Personal Heatmap algorithm, public API, persisted
schema, analysis version, UI, or importer behaviour changes. No cross-workout
counting, snapshot finalization, native library accumulator, or opaque
long-lived C++ owner is introduced.

No production migration is selected in advance. The decision is an output of
the measurements, not an input to them.

## Requirements

### Requirement 1: Profiling-Only Scope
- **1.1**: The phase MUST leave `PersonalHeatmapBuilder`, `PersonalHeatmap`
  models, `PersonalHeatmapProjection`, `PersonalHeatmapViewModel`, and the C++
  coverage kernel behaviourally unchanged.
- **1.2**: The public `PersonalHeatmapBuilder.build` entry point MUST NOT gain
  timing callbacks, logging, or signpost instrumentation.
- **1.3**: Ordinary production builds MUST contain no profiling
  instrumentation. `scripts/validate-cpp-boundaries.sh` MUST enforce this.
- **1.4**: The profiling harness MUST NOT run in ordinary CI. It MUST skip
  unless `RUNPLAY_HEATMAP_PROFILE=1`, enforced by boundary validation.
- **1.5**: No private workout data may be required. Fixtures MUST be
  deterministic and synthetic.

### Requirement 2: One Production-Equivalent Orchestration
- **2.1**: Phase timings MUST come from a single production-equivalent
  orchestration. A profiled run MUST prepare exactly one native batch and MUST
  NOT prepare a duplicate batch for a separate conversion measurement.
- **2.2**: Two modes MUST be measured separately. Mode A times the unmodified
  public production builder and is the authoritative end-to-end value. Mode B
  is a test-only profiled reconstruction of the same orchestration.
- **2.3**: Mode B MUST NOT be used as the primary product benchmark unless its
  overhead against Mode A is measured and reported.
- **2.4**: The sum of measured phases MUST be reported against the profiled
  wall-clock total, together with the unaccounted difference and its
  percentage. An attribution table MUST NOT be published when that difference
  exceeds 5% of the profiled total.

### Requirement 3: Adaptive-Pass Resolution
- **3.1**: The profile MUST distinguish every adaptive-resolution pass and
  retain a row per pass, not only the final effective resolution.
- **3.2**: Each pass row MUST report pass index, cell size, eligible workouts,
  workouts with and without coverage, coverage cells returned, invalid
  intervals, aggregated unique cells, cells passing the minimum-repeat filter,
  coverage bridge time, cross-workout count insertion time, filter time,
  adaptive decision time, pass total, and capacity retries.

### Requirement 4: Phase Decomposition
- **4.1**: Date filtering, native route preparation, per-workout coverage,
  cross-workout counting, minimum-repeat filtering, deterministic sorting, cell
  materialization, and snapshot assembly MUST be timed separately.
- **4.2**: The coverage boundary MUST be decomposed into native C++ execution,
  caller-owned output allocation including capacity retries, and C++-to-Swift
  cell translation.
- **4.3**: Any internal diagnostic added for 4.2 MUST reuse the production
  boundary implementation. A second boundary implementation MUST NOT be
  created. The diagnostic MUST expose no imported C++ type, MUST stay internal
  to `RunPlayCore`, and MUST be reachable only from tests.

### Requirement 5: Parity
- **5.1**: Every profiled reconstruction MUST be asserted exactly equal to the
  public `PersonalHeatmapBuilder` result and to
  `SwiftPersonalHeatmapBuilderOracle`, comparing complete snapshots: cells,
  cell ordering, workout counts, intensity, bounds, statistics, diagnostics,
  and effective configuration.
- **5.2**: The profile MUST fail, and its runner MUST exit nonzero, when
  semantics diverge.

### Requirement 6: Fixture Coverage
- **6.1**: The fixture matrix MUST cover a representative adaptive build
  (primary), a high-overlap library, a low-overlap library, many tiny workouts,
  few large workouts, a no-retry configuration, a repeated-coarsening
  configuration, and a higher minimum-repeat filter.
- **6.2**: The primary fixture MUST exercise multiple source segments, invalid
  coordinates, oversized intervals, rejected over-ceiling intervals, and at
  least one adaptive retry.
- **6.3**: The primary fixture MUST use at least 5 warm-ups and 20 measured
  iterations; secondary fixtures at least 3 and 10. Median, minimum, p90, and
  maximum MUST be reported for the primary fixture.
- **6.4**: Results MUST be reproducible across repeated release runs.

### Requirement 7: Memory Evidence
- **7.1**: Peak resident memory, resident memory after native preparation,
  after the largest adaptive pass, and after final snapshot construction MUST
  be recorded on macOS behind `#if canImport(Darwin)`; Linux compilation MUST
  remain valid.
- **7.2**: Resident memory MUST NOT be asserted in CI.

### Requirement 8: Existing Benchmark Correction
- **8.1**: `PersonalHeatmapCoverageBenchmark` MUST stop presenting separately
  prepared input conversion and a single final-resolution coverage sweep as
  additive components of the measured production build.
- **8.2**: Its merge-gate intent — complete production builder against
  complete Swift builder oracle — MUST be preserved, and the gated measurement
  MUST time only the public production builder.

### Requirement 9: Explicit Architecture Decision
- **9.1**: The phase MUST conclude by selecting exactly one decision: migrate
  cross-workout counting; migrate counting and finalization together; optimize
  Swift; optimize coverage-result translation; or stop heatmap migration.
- **9.2**: Recommending a native aggregation boundary requires answering input
  representation, distinct-workout counting preservation, safe native input
  bounds, whole-library product limits, chunking, maximum uninterruptible
  native duration, cancellation retention, capacity negotiation, adaptive-retry
  ownership, translation cost, and predicted end-to-end improvement.
- **9.3**: A boundary that would require an arbitrary whole-library workout or
  point limit, or an uninterruptible whole-library operation without a latency
  bound, MUST NOT be approved.
- **9.4**: Checked task boxes do not prove completion. Benchmark evidence,
  tests, and CI do.
