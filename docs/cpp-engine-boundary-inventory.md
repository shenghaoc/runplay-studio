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

## Public types

Every type, enum, and constant reachable from the umbrella header. All structs
are `final`, standard-layout, and trivially copyable (asserted by
`static_assert` in their headers); all enums are `enum class` with an explicit
`std::uint8_t` underlying type. **None of these appear in a public `RunPlayCore`
API** — they are confined to `RunPlayCore/Sources/Interop/`, which
`scripts/validate-cpp-boundaries.sh` enforces per header family.

| Header | Structs | Enums | Constants |
|---|---|---|---|
| `RunPlayEngine.hpp` | `EngineInfo` | `LanguageStandard` | — |
| `Geodesy.hpp` | `LocalMeters` | — | `earth_radius_meters` |
| `RouteInterop.hpp` | `RouteInputSample`, `RouteBatchInspection` | `RouteInteropStatus` | `max_route_input_samples` (1,250,000) |
| `RouteQualityPipeline.hpp` | `RouteQualityGeometryPolicy`, `RouteQualityOutputSample`, `RouteQualityPipelineSummary` | `RouteQualityDistancePolicy`, `RouteSegmentDistanceSource`, `RouteQualityDistanceSource`, `RouteQualityPipelineStatus` | — |
| `PersonalHeatmapCoverage.hpp` | `PersonalHeatmapRouteSample`, `PersonalHeatmapCellIndex`, `PersonalHeatmapCoverageSummary` | `PersonalHeatmapCoverageStatus` | `personal_heatmap_max_latitude_degrees`, max cells per interval |
| `RouteAlignmentDtw.hpp` | `RouteAlignmentCostSample`, `RouteAlignmentDtwPolicy`, `RouteAlignmentDtwPathCell`, `RouteAlignmentDtwSummary` | `RouteAlignmentDtwStepKind`, `RouteAlignmentDtwStatus` | — |
| `SegmentDetection.hpp` | `SegmentDetectionSample`, `SegmentDetectionConfiguration`, `SegmentWindowCandidate`, `SegmentDetectionSummary` | `SegmentWindowKind`, `SegmentDetectionStatus` | `segment_detection_max_candidate_count` (5) |
| `ElevationProfile.hpp` | `ElevationProfileInputSample`, `ElevationProfilePolicy`, `ElevationProfileOutputSample`, `ElevationProfileSummary` | `ElevationProfileStatus` | — |
| `RouteMetricScaleBuckets.hpp` | `RouteMetricScaleBucketInputSample`, `RouteMetricScaleBucketWorkspaceSample`, `RouteMetricScaleBucketPolicy`, `RouteMetricScaleBucketOutputSample`, `RouteMetricScaleBucketSummary` | `RouteMetricScaleBucketStatus` | — |

`max_route_input_samples` is the engine's internal safety ceiling, deliberately
25% above the product limit in `WorkoutImportResourceLimits` (1,000,000 route
points) so a route the app accepts can never be rejected by the engine. A parity
test enforces that relationship.

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
| `detect_segment_windows` | `const SegmentDetectionSample*` + count + config | `SegmentWindowCandidate*` + capacity | **not per-sample**: writes `candidate_count` entries, bounded by `segment_detection_max_candidate_count` (5), independent of `sample_count` |
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
- Output sizing falls into four distinct shapes; there is no single rule:
  - **Per-sample** — `process_route_quality_geometry`, `build_elevation_profile`,
    and `assign_route_metric_scale_buckets` write exactly `sample_count` entries
    on success and nothing on error.
  - **Bounded candidate set** — `detect_segment_windows` writes `candidate_count`
    entries, at most `segment_detection_max_candidate_count` (5). This is
    unrelated to `sample_count`: a 100,000-point route still yields at most five
    candidates.
  - **Capacity-negotiated** — `compute_personal_heatmap_workout_coverage` writes
    `required_cell_count` on success; on `insufficient_output_capacity` it writes
    nothing and reports the size Swift must reallocate to.
  - **Proven-bound path** — `compute_constrained_dtw_path` writes exactly
    `written_path_count`, never more than `primary + comparison + 1`.

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
  copied out on success only; failure statuses leave the output untouched and
  report `candidate_count == 0`. The written count is `candidate_count` (≤ 5),
  *not* `sample_count`; `required_output_capacity` reports the capacity needed.
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

## Verification coverage per boundary

Every boundary carries native C++ tests and a Swift parity oracle. The native
tests are one binary, so every boundary is covered by both the normal and the
ASan/UBSan run of `scripts/run-cpp-engine-tests.sh`. No C++ type is exposed to
external package consumers.

| Boundary | Native tests | Swift parity oracle | Benchmark / profile runner |
|---|---|---|---|
| `inspect_route_batch` | `RouteInteropTests.cpp` | `SwiftRouteInspectionOracle` | — (exercised via route quality) |
| `process_route_quality_geometry` | `RouteQualityPipelineTests.cpp` | `SwiftRouteQualityGeometryOracle` | `run-route-quality-benchmark.sh` |
| `compute_personal_heatmap_workout_coverage` | `PersonalHeatmapCoverageTests.cpp` | `SwiftWorkoutCoverageOracle`, `SwiftPersonalHeatmapBuilderOracle` | `run-personal-heatmap-benchmark.sh`, `run-personal-heatmap-profile.sh` |
| `compute_constrained_dtw_path` | `RouteAlignmentDtwTests.cpp` | `SwiftConstrainedDtwPathOracle`, `PreMigrationRouteAlignerOracle` | `run-route-alignment-dtw-benchmark.sh` |
| `detect_segment_windows` | `SegmentDetectionTests.cpp` | `SwiftSegmentDetectorOracle` | `run-segment-detector-benchmark.sh` |
| `build_elevation_profile` | `ElevationProfileTests.cpp` | `SwiftElevationProfileOracle` | `run-elevation-profile-benchmark.sh` |
| `assign_route_metric_scale_buckets` | `RouteMetricScaleBucketTests.cpp` | `SwiftRouteMetricScaleBucketOracle` | `run-route-metric-scale-bucket-benchmark.sh` |
| scalar geodesy | `GeodesyTests.cpp` | `GeoDistance.swift` | — |
| `engine_info` | `EngineInfoTests.cpp` | — (identity only) | — |

`scripts/run-remaining-core-hotspot-profile.sh` is cross-cutting rather than
tied to one boundary: it is a retained production diagnostic for the Swift work
that remains around the native kernels. See
[docs/cpp-engine-verification.md](cpp-engine-verification.md) for what each
runner measures and how it is invoked.

## Call cardinality

- Route quality: 1 native call per analysis.
- Personal heatmap: 1 native call per workout per adaptive resolution attempt,
  **plus at most one more for that workout when the output capacity was too
  small**. Capacity renegotiation is bounded to a single extra call — the bridge
  reallocates to `required_cell_count` and calls once more, it does not loop —
  so the per-workout-per-attempt count is 1 normally and 2 after a retry.
- Route-Aware DTW: 1 native call per alignment attempt; never per cell or row.
- Segment detection: 1 native call per search.
- Elevation profile: 1 native call per build.
- Pace/HR scale/bucket: 1 native call per finalization.
- Corrected-elevation finalization: 0 native calls.
- Solid-mode (no analysis) route inspection: 0 analysis-native calls.

These counts are asserted by `NativeCallCardinalityTests` and
`RouteMetricScaleBucketParityTests.testNativeCallCountsByMode`. Both use
`NativeCallObserver.observing`, which binds a tally to a task-local for the
duration of the measured closure, so each assertion sees only the calls its own
operation made. The observer is `#if DEBUG` only: release builds contain no
counter, no lock, and no mutable diagnostic state, and `NativeCallObserver
.record(_:)` has an empty body that optimizes away.

## Enforcement

- `scripts/validate-cpp-public-ast.py` holds the approved-pointer allow-list
  (7 pointer-bearing functions) and rejects any other public raw pointer,
  non-`noexcept` callable, or exposed standard-library container type.
- `scripts/validate-cpp-boundaries.sh` asserts each C++ symbol is invoked only
  from its designated bridge, that bridges stay under `Interop`, and that no
  production Swift file references `runplay.*` directly.
- `scripts/validate-cpp-boundaries.sh` also proves native discovery coverage by
  comparing two independently produced sets: its own `find` over the engine tree
  against `scripts/run-cpp-engine-tests.sh --list-sources`, which prints the
  exact translation units the runner hands the compiler. A newly added source or
  test that discovery misses — and equally, a runner edit that replaces `find`
  with a partial hard-coded list — changes one set but not the other and fails
  the check. Checking file locations alone would not catch the second case.
