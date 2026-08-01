# SegmentDetector C++23 Migration — Design

## Architecture

```
SegmentDetector
  → searchConfiguration (Swift policy → pure-Swift config)
  → RunPlaySegmentDetectorBridge.search
      → WorkoutTimeline.segmentDetectionSnapshot
      → ElevationProfile.segmentDetectionSnapshot
      → compact SegmentDetectionSample buffer
      → one detect_segment_windows call
      → validate + translate ≤5 candidates
  → finalizePaceCandidate / finalizeElevationCandidate
      → one evaluateWindow per winner (HR + elevation metadata)
  → public SegmentHighlight values
```

## C++ kernel

File: `RunPlayEngineCpp/Sources/SegmentDetection.cpp`

Algorithm:
1. Validate input, configuration, capacity.
2. Estimated evaluation count vs. resource limit.
3. Find fastest 400m window (independent loop).
4. Find fastest + slowest 1km windows (combined loop).
5. When elevation enabled: find biggest climb + descent (combined loop).
6. Copy to output; write nothing on error.

Distance-boundary semantics preserve both existing consumers:
- Pace clocks match `WorkoutTimeline`: same-segment plateaus use first arrival
  for both roles except the terminal end; cross-segment plateaus use the first
  resumed sample for range start and last prior sample for range end.
- Elevation values match `ElevationProfile`: exact duplicates use last for
  range start and first for range end.
- Neither path interpolates across a `continuity_group` boundary.

## Swift snapshots

- `WorkoutTimeline.segmentDetectionSnapshot()` returns copy-on-write arrays
  of distances, elapsed, active.
- `ElevationProfile.segmentDetectionSnapshot()` returns copy-on-write arrays
  of cumulative ascent/descent, reliable interval counts, run identifiers.

## Bridge

File: `RunPlayCore/Sources/Interop/RunPlaySegmentDetectorBridge.swift`

- Compacts route-segment indices into zero-based continuity groups.
- Compacts reliable elevation run identifiers into zero-based runs.
- Allocates exactly five native output entries.
- Stride-based cancellation during conversion plus checks before and after the
  native call.
- Validates: status, count, kind uniqueness, bounds, pacing/elevation ranges,
  configured window lengths, deterministic order, and evaluation counts.

## Production integration

`SegmentDetector.detectSegments` replaced five independent search loops with:
1. Build config from policy.
2. One bridge search.
3. For each candidate: validate and build highlight using existing evaluateWindow
   and makePaceHighlight / elevation finalization.
