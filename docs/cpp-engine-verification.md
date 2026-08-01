# C++ Engine Verification

This document inventories every benchmark/profile runner for the portable
`RunPlayEngineCpp` C++23 engine, the normal-vs-sanitizer participation matrix,
and the automatic-discovery coverage proof. It is a durable reference; the
scripts it describes are executable truth.

## Benchmark and profile inventory

Every runner below is opt-in: ordinary CI never sets its environment variable,
so the underlying XCTest methods skip. Each runner reports the medians it
measured on deterministic synthetic fixtures.

| Runner | Gate | Coverage |
|---|---|---|
| `scripts/run-elevation-profile-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Elevation profile kernel vs Swift oracle, deterministic fixture |
| `scripts/run-personal-heatmap-benchmark.sh` | `RUNPLAY_BENCHMARK=1`, `RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1` | Complete personal heatmap builder and aggregation |
| `scripts/run-personal-heatmap-profile.sh` | `RUNPLAY_HEATMAP_PROFILE=1` | Phase-level profile of the personal heatmap pipeline |
| `scripts/run-remaining-core-hotspot-profile.sh` | `RUNPLAY_CORE_HOTSPOT_PROFILE=1` | Release phase-level profile of remaining RunPlayCore computational hotspots (production diagnostic; `RUNPLAY_PROFILE_FAMILY` selects the family, `RUNPLAY_PROFILE_PRODUCT_LIMIT=1` enables 1M-point probes) |
| `scripts/run-route-alignment-dtw-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Constrained-DTW path solve; `RUNPLAY_BENCHMARK_MAX_BAND=1` adds the maximum-band probe |
| `scripts/run-route-metric-scale-bucket-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | C++23 route-metric numeric finalizer; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |
| `scripts/run-route-quality-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Combined route-quality geometry cutover on a deterministic 100,000-point fixture |
| `scripts/run-segment-detector-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Complete segment-detector cutover; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |

All eight runners remain present after the step-distance migration; the
transitional step-distance benchmark runner was removed with its boundary.

## Sanitizer matrix

`scripts/run-cpp-engine-tests.sh` builds the native test binary from
`find`-discovered sources and tests, and runs it in two configurations:

| Configuration | Invocation | Flags |
|---|---|---|
| Normal | `scripts/run-cpp-engine-tests.sh` | `-Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Werror`, `-O0` |
| ASan + UBSan | `scripts/run-cpp-engine-tests.sh --sanitize` | Normal flags plus `-fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer -O1`; `ASAN_OPTIONS`/`UBSAN_OPTIONS` set to halt on error |

Every native source file under `RunPlayEngineCpp/Sources` and every native test
file under `RunPlayEngineCpp/Tests` participates in both configurations by
construction: the source lists come from `find`, not from a hand-maintained
manifest. ASan leak detection is disabled on Apple platforms where the runtime
does not uniformly support it; it stays enabled elsewhere.

The Swift-side engine bridge tests additionally run under the standard
warning-clean SwiftPM suite:

- `swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors`
- `swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors`

## Discovery-coverage proof

`scripts/run-cpp-engine-tests.sh` derives both source lists with `find`:

```bash
find RunPlayEngineCpp/Sources -type f -name '*.cpp' -print | LC_ALL=C sort
find RunPlayEngineCpp/Tests   -type f -name '*.cpp' -print | LC_ALL=C sort
```

A guard in `scripts/validate-cpp-boundaries.sh` proves a source or test added
but omitted from discovery fails CI: every `*.cpp` under the engine tree must
reside under `RunPlayEngineCpp/Sources/` or `RunPlayEngineCpp/Tests/`, the two
roots the runner scans. A `.cpp` placed anywhere else in the tree (for example a
new top-level directory) fails the guard with a concrete path. Because the
runner's own lists are `find`-derived over those exact roots, a file inside
them can never be silently omitted, and a file outside them cannot escape.

Engine `.hpp` headers are scanned by the boundary validator's Apple-framework
and dependency checks; the public `include/RunPlayEngineCpp` headers are
additionally validated against the approved-pointer allow-list by
`scripts/validate-cpp-public-ast.py`.
