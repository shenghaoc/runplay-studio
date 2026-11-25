# Engine

`RunPlayEngine` is the pure Swift computational engine. This document is the
inventory of its kernels, the contract every kernel boundary follows, how each
kernel is verified, and what each benchmark and profile runner measures. It is
a durable reference. Executable truth is the engine source, the tests, and
`scripts/validate-swift-engine-boundaries.py`; if this document disagrees with
them, they win. The operating policy is in [AGENTS.md](../AGENTS.md) under
"Architecture Boundaries" and "Swift engine policy".

The engine replaced the C++23 target `RunPlayEngineCpp`. The package now has no
C or C++ target and enables no C++ interoperability. Each kernel is a literal
translation of the C++ kernel it replaced: the constants, the operation order,
and the limitations are the same.

## Kernels

Every kernel is an `enum` namespace in `RunPlayEngine/Sources` with `package`
access. Core calls each one from exactly one adapter in
`RunPlayCore/Sources/Engine`.

| Engine entry point | Core adapter (file) | Production consumer |
|---|---|---|
| `EngineRouteQuality.process` | `RunPlayRouteQualityBridge` (`RunPlayRouteQualityAdapter.swift`) | `RouteQualityProcessor` |
| `EngineElevationProfile.build` | `RunPlayElevationProfileBridge` (`RunPlayElevationProfileAdapter.swift`) | `ElevationProfile.build` |
| `PersonalHeatmapCoverage.compute` | `RunPlayPersonalHeatmapCoverageBridge` (`RunPlayPersonalHeatmapCoverageAdapter.swift`) | `PersonalHeatmapBuilder` |
| `RouteAlignmentDtw.solve` | `RunPlayRouteAlignmentDtwAdapter` | `ConstrainedDynamicTimeWarpingAligner`, `RouteGroupingMatcher` |
| `SegmentDetection.search` | `RunPlaySegmentDetectorBridge`, over `RunPlaySegmentDetectorAdapter` (`RunPlaySegmentDetectorAdapter.swift`) | `SegmentDetector` |
| `RouteMetricScaleBuckets.assign` | `RunPlayRouteMetricScaleBucketBridge` (`RunPlayRouteMetricScaleBucketAdapter.swift`) | `RouteMetricProfileBuilder` |
| `TrainingLoadKernel.compute` | `RunPlayTrainingLoadBridge` (`RunPlayTrainingLoadAdapter.swift`) | `TrainingLoadCalculator` |
| `DemTilePlanning.plan`, `DemElevationSampling.sample` | `RunPlayDemElevationBridge` (`RunPlayDemElevationAdapter.swift`) | `DEMElevationCorrector` |
| `EngineGeodesy` (coordinate validation, Haversine distance, local-metre projection) | none | none: production Core geodesy uses `GeoDistance`; the engine primitives serve the kernels and are pinned against `GeoDistance` by tests |

`RunPlayEngineLimits` projects the engine constants that Core reads: the route
input ceiling (`EngineRouteLimits.maxRouteInputSamples`) and the DEM grid
limits. `EngineCallObserver` counts engine calls for the cardinality tests.

Corrected-elevation route-metric finalization intentionally stays in Swift Core
(`RouteMetricScaleBucketSwiftFinalizer`). That is mode-owned ownership, not a
fallback, and it makes no engine call.

## Boundary contract

- Core owns every input. The engine borrows it as a `Span` for one synchronous
  call, retains nothing, and calls nothing back.
- The engine returns its output by value: an array with exactly the entries it
  produced, or a result struct. No kernel takes a caller-owned output buffer,
  negotiates capacity, or asks for a retry.
- A failed call throws the kernel's typed error (`RouteQualityError`,
  `ElevationProfileError`, `PersonalHeatmapCoverageError`,
  `RouteAlignmentDtwError`, `SegmentDetectionError`,
  `RouteMetricScaleBucketError`, `TrainingLoadError`, `DemTilePlanError`,
  `DemSamplingError`) and returns nothing.
- Allocation failure is not recoverable in Swift. The C++ kernels reported it
  as a status; the engine has no such case. Core bounds every input before the
  call (`WorkoutImportResourceLimits`, the alignment sample and band-cell
  limits, the DEM tile budget).
- Engine types have `package` access and Core imports the engine with
  `internal import`, so no engine type can appear in a public `RunPlayCore`
  signature. `RunPlayPlatform`, `RunPlayStudio` and external package consumers
  cannot import the engine.

## Call cardinality

- Route quality: 1 engine call per analysis.
- Personal heatmap: 1 engine call per workout per adaptive resolution attempt.
- Route-Aware DTW: 1 engine call per alignment attempt; never per cell or row.
- Segment detection: 1 engine call per `SegmentDetector` invocation.
- Elevation profile: 1 engine call per build.
- Pace, heart-rate and power scale/bucket finalization: 1 engine call per
  finalization. Corrected-elevation finalization and solid mode: 0.
- Training load: 1 engine call per measured pass; an estimated load uses Core
  scalar arithmetic and makes none.
- DEM elevation correction: 1 planning call and 1 sampling call per correction
  pass; 1 planning call and no sampling call when the route needs more tiles
  than the budget; 0 calls for an empty route. Tile decoding between the two
  calls is Core and Platform work.

`EngineCallCardinalityTests` and
`RouteMetricScaleBucketParityTests.testNativeCallCountsByMode` assert these
counts. Both use `EngineCallObserver.observing`, which binds a tally to a
task-local for the duration of the measured closure, so each assertion sees
only the calls its own operation made. The observer is `#if DEBUG` only:
release builds contain no counter, no lock, and no mutable diagnostic state.

## Verification

| Kernel | Engine tests (`RunPlayEngine/Tests`) | Golden digest (`RunPlayCoreTests`) | Adapter tests (`RunPlayCoreTests`) | Runner |
|---|---|---|---|---|
| Route quality | `RouteQualityTests` | `RouteQualityGoldenTests` | `RunPlayRouteQualityBridgeTests` | `run-route-quality-benchmark.sh` |
| Personal heatmap coverage | `PersonalHeatmapCoverageTests` | `PersonalHeatmapCoverageGoldenTests` | `RunPlayPersonalHeatmapCoverageBridgeTests` | `run-personal-heatmap-benchmark.sh`, `run-personal-heatmap-profile.sh` |
| Constrained DTW | `RouteAlignmentDtwTests` | `RouteAlignmentDtwGoldenTests` | `RunPlayRouteAlignmentDtwBridgeTests` | `run-route-alignment-dtw-benchmark.sh` |
| Segment detection | `SegmentDetectionTests` | `SegmentDetectionGoldenTests` | `RunPlaySegmentDetectorBridgeTests` | `run-segment-detector-benchmark.sh` |
| Elevation profile | `ElevationProfileTests` | `ElevationProfileGoldenTests` | `RunPlayElevationProfileBridgeTests` | `run-elevation-profile-benchmark.sh` |
| Scale buckets | `RouteMetricScaleBucketTests` | `RouteMetricScaleBucketGoldenTests` | `RunPlayRouteMetricScaleBucketBridgeTests` | `run-route-metric-scale-bucket-benchmark.sh` |
| Training load | `TrainingLoadTests` | `TrainingLoadGoldenTests` | `RunPlayTrainingLoadBridgeTests` | none |
| DEM planning and sampling | `DemElevationSamplingTests` | `DemElevationGoldenTests` | `RunPlayDemElevationBridgeTests` | `run-route-quality-benchmark.sh` (DEM section) |
| Geodesy and route input | `GeodesyTests`, `RouteInputSampleTests` | `GeodesyGoldenTests` (also pins the engine against `GeoDistance`) | none | `run-geodesy-benchmark.sh` |

- **Engine tests** are the C++ kernel tests, ported with the same case names.
  Cases that only a pointer boundary could express (a null buffer with a
  nonzero count, an output capacity below the result size) have no Swift form
  and were removed with the C++ engine.
- **Golden digests.** Each golden test runs a deterministic corpus through the
  engine, folds every output field into one FNV-1a-64 digest, and compares it
  with a constant pinned per CI platform (macOS arm64, Linux x86_64). The
  constants were captured while the C++ kernels still existed and a
  differential test proved the Swift and C++ outputs equal bit for bit, so the
  digests carry that proof forward. The scale-bucket constant is the one
  exception: it comes from the Swift kernel, because an equal-weight `+0`/`-0`
  tie is a decided difference (Swift's stable order gives one result on every
  platform; the C++ result depended on its standard library). A golden test is
  disabled on a platform with no pinned constant. Kernels that call the
  platform C math library (geodesy, DTW, DEM) have a different digest per
  platform.
- A change that moves a digest is a behaviour change and needs an explicit
  decision. Do not re-pin a digest to make a test pass.
- **No Swift oracles.** During the migration the test target kept the
  pre-migration Swift implementations as parity oracles. They were retired
  once the golden digests pinned every kernel: the digests are now the only
  output reference. The adapter tests assert behaviour directly (empty and
  degenerate input, contract errors, cancellation, determinism, fixed expected
  values).
- **The boundary validator** (`python3 scripts/validate-swift-engine-boundaries.py`)
  scans every Swift source and reads the SwiftPM target graph. It fails when
  the engine imports anything other than the Swift standard library and the
  platform C module; when a file other than Core sources (with
  `internal import`), the engine's tests, or a `*GoldenTests.swift` file in
  `RunPlayCoreTests` imports the engine; when a target other than Core and the
  engine tests depends on it; when a product exposes it; or when any target
  enables C++ interoperability. CI runs it on Linux, and its target-graph check
  (`--graph-only`) on every macOS run, because only macOS declares the
  Platform and Studio targets.
- **AddressSanitizer.** The Linux CI sanitizers leg runs
  `swift test --sanitize=address --filter RunPlayEngineTests` with
  LeakSanitizer on. `scripts/lsan-xctest-discovery.supp` suppresses only the
  structures that corelibs XCTest keeps until exit (its test-discovery tables
  and suite setup); a leak from code under test still fails the run. The
  engine holds every `unsafe` expression in the package (buffer
  initialization, and the unchecked span access in the elevation-profile
  stages), and strict memory safety makes each one visible in source.

## Benchmark and profile runners

Every runner is opt-in and local: CI never sets its environment variable, so
the underlying tests skip. Each runner uses a release build and reports medians
on deterministic synthetic fixtures. The benchmarks are absolute Swift
baselines: they time only the production Swift path, print no ratio, and have
no ratio gate. Machine-specific results belong in the PR that ran them, not
here.

The 1.10 times gate (complete Swift path at most 1.10 times the complete C++
path) was the migration gate. It is historical: the C++ kernels it compared
against no longer exist, and neither do the Swift oracles that the earlier
benchmarks also timed.

The route-quality, DEM, personal heatmap coverage, constrained-DTW, segment
detection and scale-bucket benchmarks print one stable line per case
(`BenchmarkBaselineLine` in `RunPlayCoreTests`):

```text
<Benchmark> <case> <count>=<value> ... iterations=<n> swift_ms=<median> [swift_max_ms=<maximum>]
```

`<Benchmark>` is the test class name, so `grep '^<Benchmark> '` selects one
benchmark's cases from a log. Resident-memory lines use the same prefix with
`bytes=<n>` (or `bytes=unavailable`). The elevation profile and heatmap engine
benchmarks keep their own single-line formats
(`ElevationProfileBenchmark <case> count=<n> swift_ms=<median>` and
`HEATMAP_ENGINE <label> swift=<median> ms`).

| Runner | Gate variable | What it measures |
|---|---|---|
| `scripts/run-elevation-profile-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | `ElevationProfileBenchmark`: the complete adapter on 1,000, 100,000 and 1,000,000 points. The 1,000,000-point case runs on every invocation |
| `scripts/run-geodesy-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | the scalar engine geodesy primitives on 100,000 and 1,000,000 pairs |
| `scripts/run-personal-heatmap-benchmark.sh` | `RUNPLAY_BENCHMARK=1`, `RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1` | the complete heatmap builder (with two independent, non-additive diagnostics), the cross-workout aggregation microbenchmark, and the complete engine path per fixture; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1,000,000-point probes |
| `scripts/run-personal-heatmap-profile.sh` | `RUNPLAY_HEATMAP_PROFILE=1` | additive phase profile of one production-equivalent heatmap build across every adaptive pass |
| `scripts/run-remaining-core-hotspot-profile.sh` | `RUNPLAY_CORE_HOTSPOT_PROFILE=1` | phase profile of the Core work around the kernels; `RUNPLAY_PROFILE_FAMILY` selects the family and `RUNPLAY_PROFILE_PRODUCT_LIMIT=1` enables the 1,000,000-point probes |
| `scripts/run-route-alignment-dtw-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | the complete adapter per fixture and in total over six fixtures, and the complete aligner; `RUNPLAY_BENCHMARK_MAX_BAND=1` adds the maximum-band probe and `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` the 1,000,000-point probe |
| `scripts/run-route-metric-scale-bucket-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | the scale-bucket finalizer across seven input shapes, plus the Platform map-line section on macOS; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1,000,000-point cases |
| `scripts/run-route-quality-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | route quality on a 100,000-point mixed fixture (complete adapter, complete `RouteQualityProcessor.process`), then DEM planning and sampling on a 100,000-point route over synthetic zoom-12 tiles; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds a 1,000,000-point probe for each |
| `scripts/run-segment-detector-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | the complete `SegmentDetector` path and the complete adapter on a 100,000-point fixture, asserting only that repeated runs give identical results; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1,000,000-point probe |

The product-limit probe is not gated uniformly: the elevation runner's
1,000,000-point case has no environment gate, and the other runners gate
theirs behind `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1`. Default-mode runtimes are
therefore not comparable across runners.
