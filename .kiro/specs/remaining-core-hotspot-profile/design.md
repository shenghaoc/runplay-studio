# Design: Remaining Core Hotspot Profile

## Profiling Harness Architecture

Follows the established `PersonalHeatmapPipelineProfile` pattern:

- Single XCTestCase class that skips unless `RUNPLAY_CORE_HOTSPOT_PROFILE=1`
- Two modes per candidate: Mode A (unmodified public entrypoint) and Mode B (profiled reconstruction with phase timings)
- Parity assertions between Mode A and Mode B outputs
- Markdown-compatible table output via `print()`
- Script `scripts/run-remaining-core-hotspot-profile.sh` wraps release build + test execution

## Environment Variables

- `RUNPLAY_CORE_HOTSPOT_PROFILE=1` — enable the profile (skips otherwise)
- `RUNPLAY_PROFILE_FAMILY=analysis|alignment|metrics|import|all` — filter candidate families (default: all)
- `RUNPLAY_PROFILE_PRODUCT_LIMIT=1` — enable 1M-point product-limit probes

## Fixture Generation

All fixtures are deterministic and synthetic. No private workout data.

### Analysis Fixtures

Synthetic route generation using `Fixtures.makeSyntheticRoute(pointCount:segments:laps:stationary:)`:

- A1: 1000 points, 1 segment, continuous movement (~5K shape)
- A2: 100_000 points, 5 segments, pauses, elevation noise
- A3: 100_000 points, 1000 tiny segments
- A4: 500 points, mixed stationary/moving
- A5: 10_000 points, altitude-heavy (sinusoidal elevation profile)
- A6: 5_000 points, 50 recorded laps
- A7: 1_000_000 points, 1 segment (product-limit probe)

### Alignment Fixtures

- B1: Two 500-point similar routes (small variations)
- B2: Two 2_000-point max-sample routes
- B3: Two 50_000-point raw routes that adaptively coarsen to 2K samples
- B4: Two 2_000-point routes with 50 segments each
- B5: Two routes with geographic noise and prefix offset

### Route Metric Fixtures

- C1: 100_000 points with pace data
- C2: 100_000 points with HR gaps
- C3: 10_000 points with sinusoidal elevation
- C4: 100_000 points with many segments
- C5: 1_000_000 points (product-limit)

### Import Fixtures

Generated from synthetic data, serialized to temp files:

For each format (JSON, GPX, TCX, FIT):
- D1: Small realistic (<1000 points)
- D2: 10_000 points
- D3: 100_000 points
- D4: Many segments
- D5: With metrics and laps
- D6: Malformed input (rejection test)

FIT additional: compressed timestamps, multi-session, timer events.

## Phase Decomposition per Family

### Analysis (Family A)

```
wall clock → route-quality (already native, measured separately)
           → timeline construction
           → elevation construction
           → derived speed/pace
           → movement profile
           → summary
           → splits
           → recorded laps
           → segment detection
           → warning/diagnostic assembly
```

Reconstruction: `WorkoutAnalysisContext` with finer-grained constructor + `WorkoutAnalyzer.analyze()`.

### Alignment (Family B)

```
wall clock → valid-point filtering
           → origin + adaptive interval
           → resampling + interpolation
           → projection
           → heading generation
           → direction detection
           → native DTW bridge
           → block construction
           → diagnostics/classification
           → aligned metrics
```

Reconstruction: copy of `ConstrainedDynamicTimeWarpingAligner.align()` logic with timing instrumentation wrapped around each phase.

### Route Metrics (Family C)

```
wall clock → input validation
           → metric extraction
           → smoothing (MetricSmoother)
           → scale/bucket calculation
           → line coalescing (RouteMetricMapLineBuilder)
```

### Import (Family D)

Per importer, per fixture:

```
wall clock → read/decompression
           → parse/decode
           → point/lap construction
           → timestamp handling
           → selection policy
           → normalization
           → elevation
           → post-normalization analysis
```

## Memory Measurement

```swift
#if canImport(Darwin)
import Darwin
func residentMemory() -> UInt64 { ... }  // task_info + mach_task_self_
#endif
```

Record: resident before, peak resident (sampled during operation via high-frequency timer), resident after.

## Statistics

```swift
func median(_ samples: [Double]) -> Double
func p90(_ samples: [Double]) -> Double
```

Standard: 5 warm-ups, 20 iterations. Large: 2 warm-ups, 5 iterations. Product-limit: 1 warm-up, 3 iterations.

## Output Format

Markdown tables matching the required PR description format:

- Fixture matrix table (point count, segments, laps, iterations)
- Phase breakdown table (ms per phase)
- Phase percent table
- Accounting residue table
- Memory table
- Candidate ranking table with 0-5 rubric scores

## File Structure

```
RunPlayCore/Tests/RunPlayCoreTests/RemainingCoreHotspotProfile.swift
  ├── RemainingCoreHotspotProfile (XCTestCase)
  │   ├── Entry point: testRemainingCoreHotspotProfile()
  │   ├── Family filter
  │   ├── Per-fixture drivers
  │   ├── Phase measurement helpers
  │   ├── Memory measurement (Darwin-guarded)
  │   └── Statistics helpers
  └── Fixture generation helpers (synthetic route builders, importer fixture generators)

scripts/run-remaining-core-hotspot-profile.sh
  └── Release build + test execution + report extraction
```
