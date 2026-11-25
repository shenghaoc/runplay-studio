#!/usr/bin/env bash
# Reproducible release benchmark for the complete SegmentDetector cutover.
#
# Set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 to add the one-million-point probe.
# Timings are reported for evidence; only exact durable highlight parity is an
# assertion. Ordinary CI skips the benchmark.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release SegmentDetector benchmark..."
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! RUNPLAY_BENCHMARK=1 \
RUNPLAY_BENCHMARK_PRODUCT_LIMIT="${RUNPLAY_BENCHMARK_PRODUCT_LIMIT:-0}" \
swift test \
  -c release \
  --filter SegmentDetectorBenchmark \
  >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi
sed -n '/RunPlay SegmentDetector benchmark/,/semantic merge gate/p' "$log"
if ! grep -Eq "Test Case .*testSegmentDetectorBenchmark.* passed" "$log"; then
  cat "$log" >&2
  echo "Expected one executed SegmentDetectorBenchmark test." >&2
  exit 1
fi

echo "Benchmark complete."
