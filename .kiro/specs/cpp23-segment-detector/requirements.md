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
- Public output ordering unchanged.

## Non-goals

Do not migrate: WorkoutTimeline construction, ElevationProfile construction,
MovementProfile, SplitCalculator, importers, public models, formatting,
persistence, or UI.
