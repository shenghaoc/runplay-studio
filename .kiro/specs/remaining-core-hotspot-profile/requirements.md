# Requirements: Remaining Core Hotspot Profile

## Implementation status

These requirements describe the **full required scope**. The PR 91 completion
implements them; they are not weakened to match a preliminary harness. Where XML
importers interleave parse with object construction, a combined phase
`XML parse + route/lap construction` is permitted and required (no fabricated
separability).

## Type

Profiling and roadmap selection only. No migration target is assumed before measurement. Production behavior, public APIs, and persisted models remain unchanged.

## Objective

Create a trustworthy, reproducible performance profile of the remaining active computational paths in `RunPlayCore`, then produce the final evidence-based migration roadmap.

## Questions to Answer

1. Which remaining production computations are materially expensive?
2. Which are already fast enough in Swift?
3. Which costs scale with route-point count?
4. Which costs are repeatedly paid during import or analysis?
5. Which groups should cross the Swift/C++ boundary together to amortize conversion?
6. Which operations require Swift cancellation, identity, policy, or model ownership and should remain Swift?
7. Whether importer migration is justified by parsing cost or whether analysis dominates end-to-end import.
8. Which next implementation phase to select.
9. How many implementation and cleanup phases remain.

## Profiling Families

### Family A: Normalized Workout Analysis

Measure through `WorkoutAnalyzer.analyze(...)` and `WorkoutAnalyzer.normalizeAndAnalyze(...)`:

- Route-quality preprocessing (already native — measure separately)
- Timeline construction
- Elevation construction (ElevationProfile)
- Derived speed/pace metrics
- Movement profile
- Summary calculation
- Splits (SplitCalculator)
- Recorded laps (RecordedLapAnalyzer)
- Segment detection (SegmentDetector)
- Warning/diagnostic assembly
- Total

### Family B: Route-Aware Alignment Outside DTW

The DTW path kernel is already native. Profile remaining Swift work:

- RouteAlignmentSampleBuilder: valid-point filtering, shared-origin calculation, adaptive interval calculation, distance-domain resampling, RoutePoint interpolation, local projection, heading construction
- Direction detection
- Native DTW bridge call
- Alignment block construction
- Diagnostics and quality classification
- Aligned metrics construction
- Total (ConstrainedDynamicTimeWarpingAligner.align)

### Family C: Map Metric Preparation

- RouteMetricProfileBuilder: metric extraction, smoothing (MetricSmoother), scale/bucket calculation
- RouteColorMetrics
- RouteMetricMapLineBuilder: line coalescing
- Cached mode switch
- Replay-tick behavior (must not rebuild)

### Family D: Import and Normalization Pipelines

For each importer (JSON, GPX, TCX, FIT, Strava archive, multi-session FIT), separate:

- File/data decoding
- Syntax or binary parsing
- Route-point construction
- Timestamp interpolation
- Session/activity selection
- Source-lap construction
- Route normalization
- Elevation construction
- Post-normalization workout analysis
- Total end-to-end import

### Family E: Active Comparison and Aggregate Analysis

- WorkoutComparisonService
- RouteAlignmentMetricsService
- WorkoutLibraryQueryService (only computation over loaded models)

## Non-Goals

- No new C++ algorithm, header, or pointer boundary
- No importer semantic or analysis output changes
- No schema or version bumps
- No optimization before measurement
- No legacy SceneKit projection (no shipped caller)
- No HealthKit, video export, iPhone companion
- No SwiftUI body rendering profiling
- No private workout data

## Fixture Requirements

### Analysis Fixtures
- A1: Ordinary 5K workout (~500-2000 points, continuous movement, HR/altitude/cadence/speed)
- A2: Long dense workout (100K points, multiple segments, pauses, elevation noise, HR/cadence, recorded laps)
- A3: Many route segments (100K points, ~1000 segments)
- A4: Stationary and intermittent movement
- A5: Altitude-heavy route
- A6: Recorded-lap-heavy workout
- A7: Product-limit probe (1M points)

### Alignment Fixtures
- B1: Ordinary similar routes
- B2: Maximum 2000-sample pair
- B3: Dense raw routes that adaptively coarsen
- B4: Many source segments
- B5: Geographic noise with prefix offset

### Route Metric Fixtures
- C1: 100K points with pace data
- C2: 100K points with HR gaps
- C3: Meaningful corrected elevation
- C4: Many route segments/bucket transitions
- C5: 1M-point product-limit probe

### Import Fixtures
For each format (JSON, GPX, TCX, FIT):
- D1: Small realistic repository fixture
- D2: 10K route points
- D3: 100K route points
- D4: Many route segments
- D5: Optional metrics and recorded laps
- D6: Malformed but safely rejected input

FIT additionally: compressed timestamps, many definitions, developer fields, multiple sessions, timer events, CRC validation
XML formats additionally: extensions, partial timestamps, multiple tracks, large attribute/text counts

## Measurement Rules

- Measure actual public/production entrypoints used by the app
- Diagnostic reconstruction may decompose phases only when it calls same production helpers, preserves order, returns equivalent result, has <15% overhead, and accounts ≥95% of wall clock
- Standard fixtures: 5 warm-ups, 20 iterations, median/p90/min/max
- Large fixtures: 2 warm-ups, 5 iterations
- 1M-point probes: 1 warm-up, 3 iterations
- No wall-clock assertions in ordinary CI

## Memory

On macOS: resident before, peak resident, resident after, largest route-sized temporary buffers. Guard with `#if canImport(Darwin)`. Linux must compile.

## Output Parity

Every fixture must assert equality between public operation output and profiled reconstruction output. Compare: route points/IDs, summary, splits, recorded laps, segments, movement diagnostics, elevation profile, analysis warnings, distance provenance, alignment snapshot, metric profile, imported workout, import diagnostics.

Non-Equatable models: implement test-only deterministic digest covering every meaningful field. Narrow tolerance only for unavoidable cross-platform floating-point values.

## Accounting

- Sum of measured phases
- Profiled wall-clock total
- Unaccounted time and percentage
- `|unaccounted %| ≤ 5%` required for phase attribution tables

## Migration-Value Rubric

Score 0-5: absolute latency, parent share, route-size scaling, execution frequency, conversion amortization, boundary simplicity, cancellation safety, output boundedness, cross-platform portability, parity-test feasibility, maintenance benefit.

Disqualifiers: no shipped caller, primarily Foundation/Apple framework work, requires new product limit, long-lived C++ ownership, callback into Swift, unacceptable uninterrupted native duration, output model tightly coupled to Swift identity/Codable, measured latency too small.

## Decision Options

1. Combined analysis kernel
2. Elevation kernel first
3. Alignment sample construction
4. Route metric profile
5. Importer migration (combined or split text/FIT)
6. Swift optimization
7. Stop production migration

## Thresholds

A migration candidate normally needs: ≥10ms on ordinary production operation, OR ≥15% of parent operation, OR clear product-limit latency/memory risk, OR high-frequency repeated execution with measurable user impact, OR substantial portability/maintenance benefit beyond speed.

## Required Final Roadmap

- Minimum, expected, and maximum remaining phase counts
- Every remaining phase: order, branch, commit subject, PR title, scope, dependency, merge gate, reason
- Final cleanup phase: retiring transitional assumptions, deciding which C++ boundaries remain test-only, removing dead Swift duplicates, cleaning headers/pointer exceptions, architecture docs, benchmarks, sanitizer matrix, package-consumer smoke, iOS portability review
