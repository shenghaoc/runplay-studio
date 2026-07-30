# Requirements: C++23 Constrained DTW Path

## Introduction

Migrate the band-constrained dynamic-time-warping path solve used by
Route-Aware comparison into C++23 and use it in production through **one**
native call per alignment attempt.

The migration is deliberately narrow. Swift continues to build the compact
alignment samples and to detect route direction before the call, and continues
to build the public alignment blocks, diagnostics, and quality after it. C++
computes exactly one constrained-DTW path and nothing else. No alignment sample
construction, aligned metric, chart, mapping, cache, or comparison-summary
logic migrates here.

Migrated numerical code is a literal translation. Constants, comparison order,
tie-breaking, and existing limitations are preserved, and statements are split
where needed so `-ffp-contract` cannot fuse a multiply-add that Swift performs
as two rounded operations.

Checked task boxes do not replace test and CI evidence.

## Requirements

### R1. Swift keeps sample construction

- `RouteAlignmentSampleBuilder` continues to own segment-aware resampling in
  cumulative-distance space, adaptive interval selection, the shared
  local-metre projection origin, normalized progress, optional heading,
  geographic-extent rejection, and route-segment preservation.
- The sample budget stays a Swift policy value: at most
  `RouteAlignmentPolicy.maximumSamplesPerRoute` = **2,000 samples per route**
  after adaptive coarsening, and at least `minimumSamplesPerRoute` before a
  solve is attempted.
- Only the four quantities that affect DTW cost cross the boundary: local
  `x`/`z` metres, normalized progress, and an optional heading. Route points,
  cumulative distances, route segment indexes, elapsed time, pace, and
  identifiers stay Swift-owned and are re-read later through the returned
  matched indexes.

### R2. Swift keeps route-direction detection

- `ConstrainedDynamicTimeWarpingAligner` continues to run the direction probe:
  coarse sample selection, ordered forward and reversed sequence cost, and mean
  heading agreement.
- Opposite-direction pairs are still rejected in Swift, before any native call.
- The detected direction is a Swift diagnostic and a Swift quality input. It is
  not a solver parameter and does not cross the boundary.

### R3. C++ computes exactly one constrained-DTW path

`compute_constrained_dtw_path` owns the whole solve and nothing beyond it:

- band radius from the band-width fraction and the unmatched prefix/suffix
  sample window;
- band-packed row layout with end expansion for an open beginning and open
  suffix;
- band-cell budget validation;
- geometry-only point cost (bounded spatial term, optional heading term,
  normalized-progress term);
- open-beginning seeding along row 0 and column 0;
- constrained transitions with exact
  diagonal → primary-only → comparison-only tie priority;
- maximum-consecutive-warp enforcement;
- open-suffix endpoint selection;
- deterministic path reconstruction in forward order.

The engine does not classify quality, build blocks, compute diagnostics,
resample, project coordinates, or decide direction.

### R4. Swift keeps blocks, diagnostics, and public models

From the returned index path, Swift continues to build anchors, split blocks at
route-segment gaps, advance and re-normalize aligned progress, enforce
monotonic distances, count diagonal and warp steps and the maximum warp run,
compute distance-weighted mean/median/p90/max separation, compute coverage
fractions and unmatched prefix/suffix, classify Excellent / Good / Limited and
every structured unavailable reason, attach warnings, and publish
`RouteAlignmentSnapshot`.

`RouteAlignmentPolicy`, `RouteAlignmentSnapshot`, `RouteAlignmentBlock`,
`RouteAlignmentAnchor`, `RouteAlignmentDiagnostics`, the `algorithmVersion`,
and the session schema are unchanged. The final gate found and fixed an existing
restoration wiring defect so the already-documented Route-Aware relaunch
behaviour now holds; this adds no new control, presentation, or schema.

### R5. One native call per alignment attempt

- Exactly **one** native call occurs per alignment attempt.
- **No** call occurs per dynamic-programming row, per cell, per sample, or per
  reconstructed path cell.
- C++ performs no callback into Swift.
- No second production DP solver exists in Swift; there is no silent fallback.
- Only `RunPlayRouteAlignmentDtwBridge` may invoke the native entry point, and
  the engine module stays confined to `RunPlayCore/Sources/Interop/`.

### R6. Bounded native operation

- The native operation is bounded by `RouteAlignmentPolicy.maximumBandCells`,
  whose product default is **4,000,000** band cells.
- The budget is checked twice: the estimated `n × (2r + 1)` band before any
  allocation, and the exact packed cell total after the row layout is built.
- Exceeding either check returns `resource_limit`, which Swift surfaces as the
  existing `.unavailable(.resourceLimit)` outcome.
- No unrestricted `n × m` matrix is ever allocated; memory is the packed band
  plus backpointers.
- Route sample count is bounded in Swift (R1), never at the engine boundary.

### R7. Boundary shape and error semantics

- The public entry point is `[[nodiscard]]` and `noexcept`. Expected failures
  return a compact status summary; no exception crosses the Swift boundary.
- `RouteAlignmentCostSample`, `RouteAlignmentDtwPolicy`,
  `RouteAlignmentDtwPathCell`, and `RouteAlignmentDtwSummary` are
  standard-layout, trivially copyable, nothrow-default-constructible aggregates
  with named fields. The public header exposes no `std::vector`, `std::pair`,
  `std::tuple`, or `std::variant`.
- Primary input, comparison input, and the path output are all Swift-owned.
  C++ borrows them synchronously, retains no pointer, and performs no callback.
- **On any failure status the output buffer is left completely unchanged** and
  `written_path_count` is zero.
- A valid path never exceeds `primary_sample_count + comparison_sample_count +
  1` cells. Swift allocates that proven upper bound, so
  `insufficient_output_capacity` is an engine contract violation rather than a
  retry signal.
- Swift validates the returned path before use: reported counts must agree,
  indexes must be in range, and consecutive cells must be consistent with the
  declared step kind. A violation raises a contract error and the aligner
  reports `.unavailable(.algorithmFailure)`.

### R8. Cancellation

- Cancellation is checked **before** the native call — while converting each
  route's samples, and again immediately before invoking the engine.
- Cancellation is checked **after** the native call, before the summary is
  interpreted.
- Cancellation is checked **during** conversion and during output translation,
  at the existing `cancellationStride`.
- Cancellation is **never** checked inside the native call. The engine takes no
  cancellation callback and has no cancellation parameter; the bounded band-cell
  budget in R6 is what keeps the uninterruptible native window bounded.
- Cancellation still surfaces as `.unavailable(.cancelled)` with no change in
  observable behaviour.

### R9. View-model and restoration invariants

- **Stale-result suppression remains in `ComparisonViewModel` and is
  unchanged**: the request-generation counter plus the alignment cancellation
  token still guarantee that a superseded pair's result never publishes.
- The in-memory alignment cache, task lifecycle, cache keying, slider mapping,
  and "slider movement never recomputes DTW" all remain unchanged.
- A restored matched-route progress value must survive the asynchronous native
  recomputation and SwiftUI's initial picker/slider reconciliation, then clamp
  against the recomputed aligned distance. A disabled slider must not replace
  the pending restored value while its real range is still unavailable.
- Alignment paths are still never written to disk.

### R10. Parity and validation

- Native C++ tests cover empty and null buffers, policy and input-contract
  rejection, band-budget rejection, no-path, endpoint selection, tie-breaking,
  warp-run capping, and the no-write-on-failure guarantee.
- A Swift path oracle reproduces the pre-migration algorithm so parity is
  asserted on the reconstructed path, not only on the final snapshot.
- Public AST validation, `./scripts/validate-cpp-boundaries.sh`, strict
  warnings, and the ASan/UBSan native runner must all pass cleanly.
- Benchmarks are opt-in and are not asserted in CI, matching the existing
  convention for earlier migrations.

### R11. Out of scope

Alignment sample construction, direction detection, aligned metrics, matched
clocks, chart points, mapping lookup, comparison summaries, splits, laps,
cross-workout heatmap aggregation, route projection services, importers,
and the persisted schema remain unchanged and out of scope. No UI is added or
restyled; the only UI-layer change is the narrow binding guard required to
preserve existing Route-Aware session-restoration behaviour.
