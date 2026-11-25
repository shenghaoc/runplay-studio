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
#   4. complete Swift adapter (conversion + solve + output validation)
#   5. complete ConstrainedDynamicTimeWarpingAligner on a workout pair
#
# The migration gate is measurement 4 versus measurement 2 (at most 1.10x).
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
# ordinary CI. RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 also probes a one-million-point
# synthetic workout through the same production compact-sampling limit.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release constrained-DTW path benchmark..."
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! RUNPLAY_BENCHMARK=1 \
RUNPLAY_BENCHMARK_PRODUCT_LIMIT="${RUNPLAY_BENCHMARK_PRODUCT_LIMIT:-0}" \
RUNPLAY_BENCHMARK_MAX_BAND="${RUNPLAY_BENCHMARK_MAX_BAND:-0}" \
swift test \
  -c release \
  --filter RouteAlignmentDtwBenchmark \
  >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi
sed -n \
    -e '/RunPlay constrained-DTW path benchmark/,/merge gate/p' \
    -e '/maximum-band probe/,/peak RSS/p' \
    -e '/product-limit probe:/p' "$log"
if ! grep -Eq "Test Case .*testRouteAlignmentDtwBenchmark.* passed" "$log"; then
  cat "$log" >&2
  echo "Expected one executed RouteAlignmentDtwBenchmark test." >&2
  exit 1
fi

echo "Benchmark complete."
