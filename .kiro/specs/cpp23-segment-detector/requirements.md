# SegmentDetector C++23 Migration — Requirements

## Objective

Move the route-wide window-search portion of `SegmentDetector` into one
allocation-free C++23 bulk kernel that selects at most five distance windows
per invocation.

## Scope

- C++ selects windows only: fastest 400m, fastest 1km, slowest 1km, biggest
  climb, biggest descent.
- Swift retains public `SegmentHighlight` models, UUIDs, titles, subtitles,
  pace/elevation formatting, final range materialization, HR averaging,
  cancellation, diagnostics, and persistence.
- One native call per `SegmentDetector` invocation.
- No native call per window, point, segment, or highlight.

## Key decisions

- 400m loop independent; 1km fastest/slowest combined into one pass.
- Climb/descent combined into one pass.
- Final HR/elevation metadata calculated only for winning windows.
- Duplicate-distance boundary ownership unchanged from Swift.
- Pace validity range [120, 1200] seconds/km preserved.
- Strict comparisons preserve first-winner ties.
- No interpolation across route gaps.
- Reliable elevation runs remain gap-safe.
- Pace clock sampling preserves `WorkoutTimeline` plateau ownership; elevation
  sampling preserves `ElevationProfile` duplicate-distance ownership.
- Pace selection divides by the actual rounded boundary distance
  (`windowEnd - windowStart`), matching Swift even at product-limit cumulative
  distances where the configured window length can differ by one ULP.
- Each of the three internal search loops retains the existing per-search
  evaluation bound.
- Public output ordering unchanged.

## Acceptance evidence

- 1,000 deterministic production-shaped candidate fixtures cover variable
  pace, stationary plateaus, pause boundaries, missing altitude, separate
  reliable elevation runs, and optional heart rate.
- The same 1,000 fixtures pass complete durable `SegmentHighlight` parity;
  UUIDs are the sole excluded field.
- Release benchmarks require exact durable-highlight parity at both 100,000
  points and the 1,000,000-point product limit.
- The post-cutover analysis profile reruns the product-limit fixture before
  the next portable-core boundary is selected.

## Non-goals

Do not migrate: WorkoutTimeline construction, ElevationProfile construction,
MovementProfile, SplitCalculator, importers, public models, formatting,
persistence, or UI.
