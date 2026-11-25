#!/usr/bin/env bash
#
# Reproducible release benchmark for the constrained-DTW path solver.
#
# Reports medians over six deterministic fixtures — near-identical 500x500,
# noisy 1000x1000, maximum-sample 2000x2000, unequal sample counts, open
# prefix/suffix, and warp-heavy — for:
#
#   1. complete engine adapter (conversion + solve + output validation), per
#      fixture and summed over all fixtures
#   2. complete ConstrainedDynamicTimeWarpingAligner on a workout pair
#
# Each case prints one stable line, "RouteAlignmentDtwBenchmark <case>
# <count>=<value> ... iterations=<n> swift_ms=<median>". The timings are an
# absolute Swift baseline with no ratio gate. Debug timings for a band-packed
# dynamic-programming sweep are meaningless — always release.
#
# Optional worst-case probe:
#
#   RUNPLAY_BENCHMARK_MAX_BAND=1 scripts/run-route-alignment-dtw-benchmark.sh
#
# adds a deterministic fixture that packs ~3.93 M band cells against the
# 4,000,000-cell policy ceiling and reports the band-cell count, the adapter
# median and maximum (swift_max_ms), and peak resident memory. It costs
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
grep -E '^(RunPlay constrained-DTW path benchmark|RouteAlignmentDtwBenchmark )' "$log" || true
if ! grep -Eq "Test Case .*testRouteAlignmentDtwBenchmark.* passed" "$log"; then
  cat "$log" >&2
  echo "Expected one executed RouteAlignmentDtwBenchmark test." >&2
  exit 1
fi

echo "Benchmark complete."
