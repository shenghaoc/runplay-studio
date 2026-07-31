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

Distance-boundary semantics match ElevationProfile.distanceLocation:
- Exact duplicate: range_start → last, range_end → first.
- Interpolation only inside one continuity_group.
- Cross-group target: start selects later, end selects earlier.

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
- One cancellation check before and after native call.
- Validates: status, count, kind uniqueness, bounds, pacing/elevation ranges,
  deterministic order.

## Production integration

`SegmentDetector.detectSegments` replaced five independent search loops with:
1. Build config from policy.
2. One bridge search.
3. For each candidate: validate and build highlight using existing evaluateWindow
   and makePaceHighlight / elevation finalization.
