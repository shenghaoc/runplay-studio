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
| `scripts/run-elevation-profile-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Elevation profile kernel vs Swift oracle, deterministic fixture. Its `E7` 1,000,000-point product-limit probe runs **unconditionally** — see the gating note below |
| `scripts/run-personal-heatmap-benchmark.sh` | `RUNPLAY_BENCHMARK=1`, `RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1` | Complete personal heatmap builder and aggregation; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |
| `scripts/run-personal-heatmap-profile.sh` | `RUNPLAY_HEATMAP_PROFILE=1` | Phase-level profile of the personal heatmap pipeline |
| `scripts/run-remaining-core-hotspot-profile.sh` | `RUNPLAY_CORE_HOTSPOT_PROFILE=1` | Release phase-level profile of remaining RunPlayCore computational hotspots (production diagnostic; `RUNPLAY_PROFILE_FAMILY` selects the family, `RUNPLAY_PROFILE_PRODUCT_LIMIT=1` enables 1M-point probes) |
| `scripts/run-route-alignment-dtw-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Constrained-DTW path solve; `RUNPLAY_BENCHMARK_MAX_BAND=1` adds the maximum-band probe |
| `scripts/run-route-metric-scale-bucket-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | C++23 route-metric numeric finalizer; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |
| `scripts/run-route-quality-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Combined route-quality geometry cutover on a deterministic 100,000-point fixture; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |
| `scripts/run-segment-detector-benchmark.sh` | `RUNPLAY_BENCHMARK=1` | Complete segment-detector cutover; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the 1M-point probe |

All eight runners remain present after the step-distance migration; the
transitional step-distance benchmark runner was removed with its boundary.

### Product-limit probe gating is not uniform

Five runners carry a 1,000,000-point probe, and they do not gate it the same
way. Four make it opt-in behind `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1`
(personal-heatmap, route-metric, route-quality, segment-detector), while
`ElevationProfileBenchmark`'s `E7 1,000,000-point product limit` case has no
environment gate at all and runs on every invocation of its runner.

This is a real inconsistency, not a documentation gap: a plain
`scripts/run-elevation-profile-benchmark.sh` pays for a 1M-point probe, whereas
a plain `scripts/run-route-metric-scale-bucket-benchmark.sh` prints
`_R7/R8 skipped; set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1._` and does not. Anyone
comparing default-mode runtimes across runners is not comparing like with like.
Unifying the gate is deliberately left out of this change because it would alter
what the elevation runner measures by default; it is recorded here so the next
change to these runners makes that choice on purpose.

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

and exposes the result — the exact translation units it hands the compiler —
through `--list-sources`:

```bash
./scripts/run-cpp-engine-tests.sh --list-sources
```

`scripts/validate-cpp-boundaries.sh` compares that output against its own
independent `find` over the whole engine tree and fails on any difference,
naming the specific files.

Comparing two separately produced sets is what makes this a proof rather than a
restatement. It closes two distinct regressions:

1. **A source or test added outside the discovery roots** — present in the
   validator's `find`, absent from the runner's list.
2. **A runner edit that replaces `find` with a partial hard-coded manifest** —
   the files still sit in the right directories, so a location-only check would
   still pass, but the runner's printed list shrinks and the comparison fails.

The second case is the one a location-only guard cannot see. Both are
negative-tested: temporarily hard-coding a two-entry test list makes the
validator report the eight dropped test files by name.

Because the compared set is the runner's real compile list, every file it covers
participates in **both** the normal and the ASan/UBSan configuration — the two
runs share one source list and differ only in flags.

Engine `.hpp` headers are scanned by the boundary validator's Apple-framework
and dependency checks; the public `include/RunPlayEngineCpp` headers are
additionally validated against the approved-pointer allow-list by
`scripts/validate-cpp-public-ast.py`.
