# Design: Final Portable Core Cleanup

## Architecture

No architectural changes. The dependency direction stays:

```text
RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngineCpp
```

The single structural change is the removal of the transitional public
step-distance boundary (`RouteGeometry.hpp` / `RouteGeometry.cpp`,
`RunPlayRouteStepDistanceBridge.swift`), leaving nine public headers and seven
pointer-bearing production callables plus the non-pointer engine identity and
geodesy primitives. Seven is the count enforced by the
`scripts/validate-cpp-public-ast.py` allow-list and recorded in
`docs/cpp-engine-boundary-inventory.md`.

```text
RunPlayEngineCpp (9 public headers)
 ├── RunPlayEngine.hpp            engine_info()
 ├── Geodesy.hpp                  is_valid_coordinate / haversine / projection
 ├── RouteInterop.hpp             inspect_route_batch()
 ├── RouteQualityPipeline.hpp     process_route_quality_geometry()
 ├── PersonalHeatmapCoverage.hpp  compute_personal_heatmap_workout_coverage()
 ├── RouteAlignmentDtw.hpp        compute_constrained_dtw_path()
 ├── SegmentDetection.hpp         detect_segment_windows()
 ├── ElevationProfile.hpp         build_elevation_profile()
 └── RouteMetricScaleBuckets.hpp  assign_route_metric_scale_buckets()
```

`Internal/RouteGeometryInternal.hpp` (pairwise step / haversine helpers)
is retained and remains private: `RouteQualityPipeline.cpp` calls
`internal::pairwise_coordinate_step_meters` and
`internal::pairwise_haversine_meters` in production.

## Step-distance removal

Files removed:

- `RunPlayEngineCpp/include/RunPlayEngineCpp/RouteGeometry.hpp`
- `RunPlayEngineCpp/Sources/RouteGeometry.cpp`
- `RunPlayEngineCpp/Tests/RouteGeometryTests.cpp` (entirely step-distance)
- `RunPlayCore/Sources/Interop/RunPlayRouteStepDistanceBridge.swift`
- `RunPlayCore/Tests/RunPlayCoreTests/RunPlayRouteStepDistanceBridgeTests.swift`
- `RunPlayCore/Tests/RunPlayCoreTests/RouteStepDistanceBenchmark.swift`
- `scripts/run-step-distance-benchmark.sh`

Edits:

- `RunPlayEngine.hpp`: drop `#include "RunPlayEngineCpp/RouteGeometry.hpp"`.
- `RunPlayEngineCpp/Tests/TestMain.cpp`: drop `run_route_geometry_tests()`.
- `scripts/validate-cpp-boundaries.sh`: remove the geometry-header presence and
  umbrella checks, the step-distance signature check, the
  `STEP_DISTANCE_BRIDGE_SOURCE` presence check, the step-distance symbol
  matcher/leak checks, and the RouteQualityProcessor / quality-bridge
  step-distance negative checks.
- `scripts/validate-cpp-public-ast.py`: remove the
  `compute_route_step_distances` approved-pointer entry and all step-distance
  adversarial fixtures; replace a few fixtures that only exercised
  step-distance mutability rules with equivalent route-quality fixtures where
  the adversarial intent is preserved.
- `Package.swift`: remove the "transitional bulk step-distance boundary"
  comment fragment.

Docs updated (no stale step-distance references, migration marked complete):

- `AGENTS.md` (engine description, approved pointer boundaries)
- `README.md` (engine summary, cutover paragraph)
- `docs/architecture.md` (engine summary, ownership, approved boundaries)
- `docs/phase-plan.md` (cleanup checked, remaining count 0, step-distance prose)

## Disposition decisions

| Item | Decision | Rationale |
| --- | --- | --- |
| `compute_route_step_distances` | Remove | No shipped production caller; only migration-era tests/benchmarks |
| `Internal/RouteGeometryInternal.hpp` | Retain | Production `RouteQualityPipeline.cpp` uses both helpers |
| `Swift*Oracle.swift` files | Retain | Each is an active parity oracle referenced by parity/bridge/benchmark tests |
| `PreMigrationRouteAlignerOracle.swift` | Retain | End-to-end aligner parity oracle; referenced by `DynamicTimeWarpingRouteAlignerTests` |
| `RemainingCoreHotspotProfile.swift` + runner | Retain | General production diagnostic; reframe any migration-decision-only ranking prose |
| `GeoDistance` | Retain | Independent Swift geodesy reference; production still uses it for remaining Swift stages |
| `RouteMetricScaleBucketSwiftFinalizer` | Retain | Intentional corrected-elevation production Swift ownership, not a fallback |
| `run-cpp-engine-tests.sh` | Retain | Already uses automatic `find` discovery; add a discovery-coverage guard |
| `Tests/PackageConsumerSmoke` | Strengthen | Add representative `RunPlayCore` usage beyond a bare import; compile **and** run (runtime `precondition`s) |

## Call cardinality

| Production caller | Native call count per operation |
| --- | --- |
| `RouteQualityProcessor.process` | 1 (route quality) + 1 (elevation) |
| `PersonalHeatmapBuilder` per workout per attempt | 1, or 2 when the output capacity was too small (bounded single capacity renegotiation) |
| `ConstrainedDynamicTimeWarpingAligner.align` | 1 per alignment attempt |
| `SegmentDetector.detect` | 1 |
| `ElevationProfile.build` | 1 |
| `RouteMetricProfileBuilder` pace / HR finalize | 1 each |
| `RouteMetricProfileBuilder` corrected elevation | 0 (Swift finalizer) |
| solid mode | 0 |

Cardinality tests observe the bridge layer through `NativeCallObserver`, which
is `#if DEBUG` only. Release builds carry no counter, no lock, and no mutable
diagnostic state, so production behaviour is genuinely unchanged. Observation is
scoped to a task-local for the duration of the measured closure rather than
reset on process-wide state, so a concurrently running test cannot pollute a
count.

## Discovery coverage guard

`run-cpp-engine-tests.sh` builds every `RunPlayEngineCpp/Sources/*.cpp` and
`RunPlayEngineCpp/Tests/*.cpp` via `find ... | LC_ALL=C sort`, and exposes the
resulting list through `--list-sources`.

`validate-cpp-boundaries.sh` compares that output against its own independent
`find` over the engine tree. Comparing two separately produced sets is what
makes the guard meaningful: a file added but omitted from discovery fails, and
so does a runner edit that swaps `find` for a partial hard-coded manifest.
Checking only that each `.cpp` sits under `Sources/` or `Tests/` would catch the
first case but not the second.
