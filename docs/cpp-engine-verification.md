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

## Per-runner reference

What each runner measures and why it is retained. Machine-specific timings are
deliberately absent — execution evidence belongs in the PR that ran them, and
the numbers below are policy (fixture sizes, iteration counts), not results.

### `run-elevation-profile-benchmark.sh`

- **Harness:** `ElevationProfileBenchmark` (swift-testing, release).
- **Fixtures / policy:** E1 1,000 points (5 warm-ups + 20 measured), E2 100,000
  dense-altitude points (2 + 5), E7 1,000,000-point product limit (1 + 3,
  currently ungated — see the gating note above). Medians reported.
- **Conversion:** the complete-bridge median includes Swift→C++ conversion;
  input conversion, output allocation, native kernel, and output translation are
  itemized separately, with the native maximum also reported.
- **Role:** merge gate — complete bridge against the retained Swift oracle.
- **Memory:** none reported.
- **Retention rationale:** guards the elevation-profile kernel cutover; the
  oracle comparison is the regression tripwire for the multi-pass kernel.

### `run-personal-heatmap-benchmark.sh`

- **Harnesses:** `PersonalHeatmapCoverageBenchmark` and
  `PersonalHeatmapAggregationBenchmark` (XCTest, release).
- **Fixtures / policy:** coverage — 250 workouts × 1,000 points, 5 + 20,
  medians. Aggregation — five dictionary-shape fixtures (≈900k updates/≈300k
  unique, high overlap, low overlap, many tiny workouts, negative cell indexes),
  5 + 20. Product-limit probe (gated): one workout × 1,000,000 points, 5
  iterations, native median/max.
- **Conversion:** the merge-gate number is the complete production builder; the
  printed conversion and native-total timings are independent diagnostics on
  separately prepared batches, documented in-file as non-additive.
- **Role:** merge gate — complete production builder vs the complete
  pre-migration Swift builder oracle.
- **Memory:** resident RSS after benchmark; probe reports peak RSS.
- **Retention rationale:** guards the per-workout coverage kernel and the Swift
  cross-workout aggregation that stayed behind.

### `run-personal-heatmap-profile.sh`

- **Harness:** `PersonalHeatmapPipelineProfile` (XCTest, release).
- **Fixtures / policy:** eight fixtures A–H spanning primary, overlap styles,
  many-tiny (5,000 × 20) and few-large (10 × 25,000) shapes; 3 + 10 per fixture.
- **Conversion:** native execution is split from output allocation and direct
  native-buffer counting inside one production-equivalent orchestration; every
  adaptive pass is attributed.
- **Role:** diagnostic — the additive phase decomposition. Enforces ≤ 5%
  unaccounted residue per fixture and suppresses attribution tables beyond it;
  the threshold is load-sensitive on small-absolute-time fixtures (fixture D).
- **Memory:** peak resident plus resident after native preparation, after the
  largest adaptive pass, and after final snapshot.
- **Retention rationale:** the only additive source of truth for where heatmap
  wall-clock goes; the coverage benchmark's diagnostics are documented as
  non-additive.

### `run-remaining-core-hotspot-profile.sh`

- **Harnesses:** `RemainingCoreHotspotProfile` and
  `RemainingPlatformHotspotProfile` (XCTest, release).
- **Fixtures / policy:** five families selected via `RUNPLAY_PROFILE_FAMILY` —
  analysis, alignment, metrics, import, comparison — each with in-file fixture
  policies; product-limit probes (A7, C5) gated on
  `RUNPLAY_PROFILE_PRODUCT_LIMIT=1`; extra memory reporting on
  `RUNPLAY_PROFILE_MEMORY=1`.
- **Conversion:** attributes the Swift work that remains around the native
  kernels, not the kernels themselves.
- **Role:** production diagnostic; no merge gate.
- **Memory:** opt-in via `RUNPLAY_PROFILE_MEMORY=1`.
- **Retention rationale:** locates remaining Swift cost around the migrated
  kernels so future optimization PRs target measured hotspots, not guesses.

### `run-route-alignment-dtw-benchmark.sh`

- **Harness:** `RouteAlignmentDtwBenchmark` (XCTest, release).
- **Fixtures / policy:** six fixtures (near-identical 500×500, noisy 1000×1000,
  maximum-sample 2000×2000, unequal 1800×900, open-prefix/suffix 1200×1170,
  warp-heavy 1500×1500), 5 + 20, per-fixture medians; complete-aligner timing on
  a 2000-sample pair. Maximum-band probe (8000×8000, ≈3.93M of 4M allowed band
  cells) gated on `RUNPLAY_BENCHMARK_MAX_BAND=1`.
- **Conversion:** the C++ bridge column includes conversion; the native kernel
  is a separate column.
- **Role:** merge gate — complete C++ bridge ≤ ~1.25× complete Swift oracle.
- **Memory:** peak RSS reported; probe reports its own peak RSS.
- **Retention rationale:** guards the constrained-DTW solve and pins the
  `maximumBandCells` budget with a near-worst-case probe.

### `run-route-metric-scale-bucket-benchmark.sh`

- **Harness:** `RouteMetricScaleBucketBenchmark` (XCTest, release), plus the
  platform map-line section of `RemainingPlatformHotspotProfile` on Darwin.
- **Fixtures / policy:** R1 1k pace (5 + 20); R2–R6 100k variants — pace, HR
  gaps, elevation, no-scale, duplicates/zero (2 + 5 each); product-limit R7 1M
  pace (1 + 3) and R8 complete three-mode probe, gated.
- **Conversion:** itemized — conversion, output allocation, native, translation,
  and public materialization columns alongside the complete bridge; native
  maximum reported per fixture.
- **Role:** merge gate — Swift oracle vs complete bridge per fixture.
- **Memory:** resident and high-water before/after.
- **Retention rationale:** guards the route-metric numeric finalizer across its
  distinct input shapes; the no-scale and duplicates fixtures pin the early-exit
  paths.

### `run-route-quality-benchmark.sh`

- **Harness:** `RouteQualityPipelineBenchmark` (XCTest, release).
- **Fixtures / policy:** one deterministic 100,000-point mixed fixture
  (segments/outliers/gaps/supplied distances), 5 + 20, medians; product-limit
  probe 1,000,000 points × 3 native-kernel iterations, gated.
- **Conversion:** four timings — Swift stages 2–4 oracle, complete combined
  bridge (conversion + C++ + projection), native path alone, and the complete
  `RouteQualityProcessor.process`.
- **Role:** merge gate — complete combined bridge ≤ ~1.25× the Swift stages 2–4
  oracle.
- **Memory:** the product-limit probe reports peak RSS.
- **Retention rationale:** guards the largest single kernel cutover; the
  processor timing keeps the end-to-end cost visible alongside the kernel.

### `run-segment-detector-benchmark.sh`

- **Harness:** `SegmentDetectorBenchmark` (XCTest, release).
- **Fixtures / policy:** 100,000-point four-segment fixture with elevation and
  heart rate, 3 + 10, medians; product-limit 1,000,000-point probe (1 + 3),
  gated.
- **Conversion:** complete production path vs the pre-migration Swift oracle.
- **Role:** merge gate — semantic, not only temporal: exact durable highlight
  digest parity between the two paths, plus the ratio.
- **Memory:** none reported.
- **Retention rationale:** the digest-parity gate is the only end-to-end
  semantic check that the C++ window search selects identical segments.

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
