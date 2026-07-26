# Design: Route-Aware DTW Comparison

## Layers

- **RunPlayCore**: `ComparisonAlignmentMode`, `RouteAlignmentPolicy`, sample builder, constrained DTW aligner, snapshot/mapping models, metrics service, accessibility summary fields.
- **RunPlayStudio**: `ComparisonViewModel`, AppState session integration, Compare/Map/Chart UI, session schema v2.

## Pipeline

1. Segment-aware resample in cumulative-distance space (adaptive interval, shared local projection origin).
2. Direction probe (forward vs reverse coarse cost).
3. Band-constrained DTW with open prefix/suffix, warp-run caps, geometry-only point cost.
4. Path → monotonic anchors → gap-split blocks → quality classification.
5. Mapping API for O(log n) slider lookup; matched clocks and chart points from immutable snapshot.

## Complexity

- Preparation: O(route points)
- DTW: O(samples × bandWidth)
- Slider lookup: logarithmic / bounded
- No DTW recompute on interaction

## Session

- `AppSessionSnapshot.currentVersion = 2`
- Comparison state adds `alignmentModeRaw` and `alignedProgressMeters`
- v1 decode defaults missing fields to Distance / 0
