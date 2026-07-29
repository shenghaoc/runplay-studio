#!/usr/bin/env bash
#
# Reproducible release benchmark for the constrained-DTW path cutover.
#
# Reports medians over six deterministic fixtures — near-identical 500x500,
# noisy 1000x1000, maximum-sample 2000x2000, unequal sample counts, open
# prefix/suffix, and warp-heavy — plus a per-fixture and total comparison of:
#
#   1. complete Swift path oracle
#   2. complete C++ bridge (conversion + native solve + output validation)
#   3. native kernel alone, on already-converted inputs (attribution only)
#   4. complete ConstrainedDynamicTimeWarpingAligner on a workout pair
#
# The primary merge gate is measurement 2 versus measurement 1.
# Debug timings for a band-packed dynamic-programming sweep are meaningless —
# always release.
#
# Optional worst-case probe:
#
#   RUNPLAY_BENCHMARK_MAX_BAND=1 scripts/run-route-alignment-dtw-benchmark.sh
#
# adds a deterministic fixture that packs ~3.93 M band cells against the
# 4,000,000-cell policy ceiling and reports the band-cell count, native median,
# native maximum, complete bridge duration, and peak resident memory. It costs
# roughly 40 MB of engine-side state, so it is opt-in and is not part of
# ordinary CI.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release constrained-DTW path benchmark..."

RUNPLAY_BENCHMARK=1 \
RUNPLAY_BENCHMARK_MAX_BAND="${RUNPLAY_BENCHMARK_MAX_BAND:-0}" \
swift test \
  -c release \
  --filter RouteAlignmentDtwBenchmark \
  2>&1 | sed -n \
    -e '/RunPlay constrained-DTW path benchmark/,/merge gate/p' \
    -e '/maximum-band probe/,/peak RSS/p'

echo "Benchmark complete."
