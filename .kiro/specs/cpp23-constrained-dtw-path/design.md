# Design: C++23 Constrained DTW Path

## Architecture

```text
RunPlayStudio
    └── ComparisonViewModel
            request generation + cancellation token (stale suppression, unchanged)
    ↓
RunPlayPlatform
    ↓
RunPlayCore
    ├── RouteAlignmentSampleBuilder        (Swift: compact alignment samples)
    ├── ConstrainedDynamicTimeWarpingAligner
    │       ├── direction probe            (Swift)
    │       ├── one bulk solve             ↓
    │       └── blocks / diagnostics / quality / snapshot (Swift)
    └── RunPlayRouteAlignmentDtwBridge     (Interop, one native call)
            ↓
      RunPlayEngineCpp
      ├── RouteAlignmentCostSample
      ├── RouteAlignmentDtwPolicy
      ├── RouteAlignmentDtwPathCell / RouteAlignmentDtwSummary
      └── compute_constrained_dtw_path
```

## Data flow

```text
Swift RunWorkout pair
    → Swift [RouteAlignmentSample] per route (≤ 2,000 samples per route)
    → Swift direction probe (opposite direction rejected here)
    → two ContiguousArray<RouteAlignmentCostSample> inputs
      + one ContiguousArray<RouteAlignmentDtwPathCell> output sized n + m + 1
    → one compute_constrained_dtw_path call
    → Swift path validation → anchors → blocks → diagnostics → quality
    → RouteAlignmentSnapshot
```

Swift owns all three buffers. C++ borrows them only for the synchronous call
and retains none of them. On success C++ writes exactly `written_path_count`
entries; **on any failure status the output buffer is left completely
unchanged** and `written_path_count` is zero.

## C++ boundary

```cpp
[[nodiscard]]
RouteAlignmentDtwSummary compute_constrained_dtw_path(
    const RouteAlignmentCostSample* primary_samples,
    std::size_t primary_sample_count,
    const RouteAlignmentCostSample* comparison_samples,
    std::size_t comparison_sample_count,
    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,
    RouteAlignmentDtwPolicy policy,
    RouteAlignmentDtwPathCell* output_path,
    std::size_t output_capacity
) noexcept;
```

Approved public pointer surfaces become:

1. `inspect_route_batch` — const route input samples
2. `compute_route_step_distances` — const route input samples plus caller-owned
   `double*` output
3. `process_route_quality_geometry` — const route input samples, optional const
   selection bytes, caller-owned `RouteQualityOutputSample*` output
4. `compute_personal_heatmap_workout_coverage` — const heatmap route samples plus
   caller-owned `PersonalHeatmapCellIndex*` output (capacity-negotiated)
5. `compute_constrained_dtw_path` — const primary and comparison
   `RouteAlignmentCostSample*` inputs plus caller-owned
   `RouteAlignmentDtwPathCell*` output

### Value types

`RouteAlignmentCostSample` carries only the four quantities that affect DTW
cost: local `x`/`z` metres, normalized progress, and a heading with an explicit
`has_heading` flag standing in for Swift's optional. `RouteAlignmentDtwPolicy`
carries only the ten fields the solver reads; quality thresholds, chart policy,
geographic extent, sample-building policy, algorithm version, and cancellation
are deliberately absent. Every public aggregate is standard-layout and
trivially copyable with named members.

Swift maps a negative `maximumConsecutiveWarpSteps` or `maximumBandCells` to
zero before crossing, which preserves the Swift comparisons exactly: zero warp
steps forbids every non-diagonal transition, and a zero cell budget always
reports `resource_limit`.

## Solve

The kernel is a literal translation of the pre-migration Swift solve:

1. **Band radius** — `ceil(max(n, m) × bandWidthFraction)`, floored at 1 and
   raised to the unmatched prefix/suffix sample window derived from the
   policy's metre and fraction limits.
2. **Band budget** — estimated `n × (2r + 1)` is rejected before allocation if
   it exceeds `maximum_band_cells`.
3. **Row layout** — each row's centre is the proportional projection of the row
   onto the comparison axis; the band is expanded to column 0 near the start and
   to the last column near the end so an open beginning and open suffix stay
   reachable. The exact packed total is re-checked against `maximum_band_cells`.
4. **Point cost** — bounded spatial term, optional heading term normalized over
   0…π, and normalized-progress term. Statements are split so `-ffp-contract`
   cannot fuse a multiply-add Swift performs as two rounded operations.
5. **Seeding** — comparison prefix along row 0 and primary prefix down column 0,
   each limited to the open-sample window and charged a quarter penalty.
6. **Transitions** — diagonal, then primary-only, then comparison-only,
   replacing only on a strictly lower candidate. That evaluation order *is* the
   tie priority. Warp runs are tracked per cell and capped.
7. **Endpoint** — best reachable cell within the open-suffix window; no
   reachable cell yields `no_path`.
8. **Reconstruction** — backpointer walk with a guard counter, reversed into
   forward order.

## Resource bound

The native operation is bounded by `maximumBandCells`, product default
**4,000,000**. Combined with the Swift cap of 2,000 samples per route, the
packed band, backpointers, and warp-run state are all bounded before any
allocation happens. No unrestricted `n × m` matrix is allocated.

## Cancellation

```text
during Swift conversion of each route's samples   (cancellationStride)
immediately before the native call
immediately after the native call
during Swift translation of the output path       (cancellationStride)
```

Cancellation is **never** checked inside the native call. The engine has no
cancellation parameter and takes no callback, so the bounded band budget is what
keeps the uninterruptible native window bounded. Cancellation continues to
surface as `.unavailable(.cancelled)`.

## Status mapping

| Native status | Swift bridge | Aligner outcome |
| --- | --- | --- |
| `success` | validated path | blocks, diagnostics, quality |
| `resource_limit` | `.resourceLimit` | `.unavailable(.resourceLimit)` |
| `no_path` | `.noPath` | `.unavailable(.routesTooFarApart)` |
| `invalid_policy` | thrown | `.unavailable(.algorithmFailure)` |
| `invalid_input_contract` | thrown | `.unavailable(.algorithmFailure)` |
| `allocation_failure` | thrown | `.unavailable(.algorithmFailure)` |
| buffer / capacity / internal | engine contract violation | `.unavailable(.algorithmFailure)` |

Swift additionally rejects a returned path whose counts disagree, whose indexes
fall out of range, or whose consecutive cells contradict the declared step kind.

## View-model integration

`ComparisonViewModel` is untouched. Its request-generation counter and
alignment cancellation token still suppress stale results from a superseded
workout pair, the in-memory cache still avoids recomputation, and slider
movement still never triggers a solve.

## Non-goals

Alignment sample construction, direction detection, aligned metrics, matched
clocks, chart points, mapping lookup, comparison summaries, splits, recorded
laps, cross-workout heatmap aggregation, route projection services, importers,
persisted schema, `algorithmVersion`, and UI are all out of scope.
