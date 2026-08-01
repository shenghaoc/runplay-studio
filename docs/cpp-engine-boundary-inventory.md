# C++ Engine Boundary Inventory

**Transitional boundaries remaining: 0.** The sole transitional boundary
(`compute_route_step_distances`) has been removed; every remaining public
callable is a production kernel or a parity/test-focused geodesy primitive.

This document is the canonical inventory of the public `RunPlayEngineCpp` C++23
boundary surface. It exists so the set of Swift-facing C++ entry points can be
reviewed as a whole: every pointer-bearing function, its ownership contract,
its Swift facade, and its call cardinality.

This file is a durable reference. Executable truth lives in the public headers,
`scripts/validate-cpp-public-ast.py` (the approved-pointer allow-list), and
`scripts/validate-cpp-boundaries.sh` (structural checks). If this inventory
disagrees with the validators, the validators win.

## Headers

Nine public headers live under `RunPlayEngineCpp/include/RunPlayEngineCpp/`:

| Header | Content |
|---|---|
| `RunPlayEngine.hpp` | Umbrella include, engine identity (`engine_info`) |
| `Geodesy.hpp` | Scalar, allocation-free geodesy primitives (parity/test-focused) |
| `RouteInterop.hpp` | Route value contract, `RouteInputSample`, `inspect_route_batch` |
| `RouteQualityPipeline.hpp` | Combined route-quality geometry kernel |
| `PersonalHeatmapCoverage.hpp` | Per-workout personal heatmap coverage kernel |
| `RouteAlignmentDtw.hpp` | Constrained-DTW path solver |
| `SegmentDetection.hpp` | Segment window-search kernel |
| `ElevationProfile.hpp` | Multi-pass elevation profile kernel |
| `RouteMetricScaleBuckets.hpp` | Route-metric scale/bucket assignment kernel |

There is no standalone step-distance header: the transitional bulk
`compute_route_step_distances` boundary was removed. The route-quality kernel
reuses internal pairwise step helpers (`internal::pairwise_*` in
`RunPlayEngineCpp/Sources/Internal/RouteGeometryInternal.hpp`) directly.

## Pointer-bearing public functions

Seven functions carry raw pointers across the Swift boundary. C++ borrows every
buffer synchronously, retains nothing, and performs no callback. Swift owns
every buffer. Each boundary is exactly one call per logical operation.

| Function | Inputs | Outputs | Capacity semantics |
|---|---|---|---|
| `inspect_route_batch` | `const RouteInputSample*` + count | — (return value) | n/a |
| `process_route_quality_geometry` | `const RouteInputSample*` + count; optional `const std::uint8_t*` selection + count | `RouteQualityOutputSample*` + capacity | per-sample: writes exactly `sample_count` entries on success |
| `compute_personal_heatmap_workout_coverage` | `const PersonalHeatmapRouteSample*` + count + scalars | `PersonalHeatmapCellIndex*` + capacity | capacity-negotiated: writes `required_cell_count` on success, nothing + count on `insufficient_output_capacity` |
| `compute_constrained_dtw_path` | `const RouteAlignmentCostSample*` ×2 + counts + scalars | `RouteAlignmentDtwPathCell*` + capacity | writes exactly `written_path_count` on success; upper bound proven (`primary + comparison + 1`); insufficient capacity is a contract violation |
| `detect_segment_windows` | `const SegmentDetectionSample*` + count + config | `SegmentWindowCandidate*` + capacity | writes exactly `sample_count` entries on success |
| `build_elevation_profile` | `const ElevationProfileInputSample*` + count + policy | `ElevationProfileOutputSample*` + capacity | writes exactly `sample_count` entries on success |
| `assign_route_metric_scale_buckets` | `const RouteMetricScaleBucketInputSample*` + count + policy | `RouteMetricScaleBucketWorkspaceSample*` (typed workspace) + `RouteMetricScaleBucketOutputSample*` + capacities | writes exactly `sample_count` output entries on success |

Geodesy primitives (`is_valid_coordinate`, `haversine_distance_meters`,
`project_lat_lon_to_local_meters`, `earth_radius_meters`) are scalar
value-returning `noexcept` functions with no raw pointers. They are parity and
test-focused: production Swift geodesy uses `GeoDistance`, and production
route-quality geometry goes through the combined kernel.

## Ownership and lifetime rules

- **Swift owns every buffer.** C++ borrows input and output buffers for the
  duration of the synchronous call only. The native pointer never escapes
  Interop; C++ retains nothing.
- **No exceptions** cross the boundary. Every public function is `noexcept`.
- **No callbacks** into Swift. Cancellation is cooperative Swift work checked
  before and after each native call, never inside it.
- **No `std::vector` / `std::pair` / `std::tuple` / `std::variant`** in public
  Swift-facing APIs. Value-returning functions name their fields through
  standard-layout aggregates (e.g. `LocalMeters`).
- Per-sample boundaries write exactly `sample_count` output entries on success
  and write nothing on error. The personal heatmap boundary is
  capacity-negotiated instead (see table); the DTW boundary writes exactly
  `written_path_count` on success.

## Pointer/lifetime audit (workstream R3)

Each public callable was audited in its source implementation against the
contract above. Findings:

- **`inspect_route_batch`** (`RouteInterop.cpp`): input-only, value-returning.
  Rejects null buffers and sample-count over the engine ceiling before any
  work.
- **`process_route_quality_geometry`** (`RouteQualityPipeline.cpp`): returns
  `empty_summary(insufficient_output_capacity)` without touching the output
  buffer when capacity is short; writes exactly `sample_count` entries on
  success. Optional selection buffer must pair with a valid count.
- **`compute_personal_heatmap_workout_coverage`**
  (`PersonalHeatmapCoverage.cpp`): capacity-negotiated. On
  `insufficient_output_capacity` it sets `written_cell_count = 0` and returns
  before the output write loop; on success it writes exactly
  `required_cell_count` entries. Deterministic ordering (row-major Y then X)
  happens in an internal vector, then is copied out.
- **`compute_constrained_dtw_path`** (`RouteAlignmentDtw.cpp`): the only output
  write is the single loop after every failure check; on any failure status the
  output buffer is left completely unchanged. Writes exactly
  `written_path_count` on success. Capacity lower than the proven path bound is
  reported as `insufficient_output_capacity`.
- **`detect_segment_windows`** (`SegmentDetection.cpp`): candidates are built in
  an internal array bounded by `segment_detection_max_candidate_count`, then
  copied out on success only; failure statuses leave the output untouched.
- **`build_elevation_profile`** (`ElevationProfile.cpp`): writes exactly
  `sample_count` output entries on success; returns early (writing nothing) on
  invalid buffer, insufficient capacity, invalid policy, or invalid input
  contract.
- **`assign_route_metric_scale_buckets`** (`RouteMetricScaleBuckets.cpp`):
  verifies input, workspace, and output buffers plus both capacities before any
  write; writes exactly `sample_count` output entries on success. The typed
  caller-owned workspace is an eligible-pair scratch area, not a Swift callback
  or heap allocation.
- **Geodesy primitives** (`Geodesy.cpp`): scalar value returns, no raw
  pointers; parity/test-focused.
- **Engine identity** (`RunPlayEngine.cpp`): `engine_info()` is a value return.

All functions are `noexcept`; all pointer inputs are `const`; all outputs are
caller-owned mutable pointers with explicit capacities. No `std::shared_ptr`,
raw non-owning stored pointers, `reinterpret_cast`, mutable global state, or
manual memory management appears at or behind the public boundary.

## Swift facade mapping

Each public pointer boundary is consumed by exactly one Interop bridge under
`RunPlayCore/Sources/Interop/`. Production Swift never touches `runplay.*`
symbols directly.

| C++ boundary | Swift bridge | Production consumer |
|---|---|---|
| `inspect_route_batch` | `RunPlayRouteBridge` | route-size validation preflight |
| `process_route_quality_geometry` | `RunPlayRouteQualityBridge` | `RouteQualityProcessor` |
| `compute_personal_heatmap_workout_coverage` | `RunPlayPersonalHeatmapCoverageBridge` | personal heatmap builder (one call per workout per adaptive attempt) |
| `compute_constrained_dtw_path` | `RunPlayRouteAlignmentDtwBridge` | Route-Aware aligner (one call per alignment attempt) |
| `detect_segment_windows` | `RunPlaySegmentDetectorBridge` | segment detector |
| `build_elevation_profile` | `RunPlayElevationProfileBridge` | elevation profile builder |
| `assign_route_metric_scale_buckets` | `RunPlayRouteMetricScaleBucketBridge` | `RouteMetricProfileBuilder` (pace/HR path) |
| scalar geodesy | `RunPlayGeodesyBridge` | parity/tests only |

Corrected-elevation route-metric finalization intentionally stays in Swift
(`RouteMetricScaleBucketSwiftFinalizer`); it is mode-owned ownership, not a
fallback, and makes zero native calls.

## Call cardinality

- Route quality: 1 native call per analysis.
- Personal heatmap: 1 native call per workout per adaptive resolution attempt.
- Route-Aware DTW: 1 native call per alignment attempt; never per cell or row.
- Segment detection: 1 native call per search.
- Elevation profile: 1 native call per build.
- Pace/HR scale/bucket: 1 native call per finalization.
- Corrected-elevation finalization: 0 native calls.
- Solid-mode (no analysis) route inspection: 0 analysis-native calls.

## Enforcement

- `scripts/validate-cpp-public-ast.py` holds the approved-pointer allow-list
  (7 pointer-bearing functions) and rejects any other public raw pointer,
  non-`noexcept` callable, or exposed standard-library container type.
- `scripts/validate-cpp-boundaries.sh` asserts each C++ symbol is invoked only
  from its designated bridge, that bridges stay under `Interop`, and that no
  production Swift file references `runplay.*` directly.
- `scripts/validate-cpp-boundaries.sh` also asserts the native test runner
  (`scripts/run-cpp-engine-tests.sh`) derives its source lists from `find`
  discovery, so newly added C++ sources/tests cannot silently escape coverage.
