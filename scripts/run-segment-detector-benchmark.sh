#!/usr/bin/env bash
# Reproducible release benchmark for the complete SegmentDetector.
#
# Set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 to add the one-million-point probe.
# Each case prints one stable line, "SegmentDetectorBenchmark <case>
# <count>=<value> ... iterations=<n> swift_ms=<median>". The timings are an
# absolute Swift baseline with no ratio gate; the only assertions are that
# repeated runs give identical results. Ordinary CI skips the benchmark.

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
grep -E '^(RunPlay SegmentDetector benchmark|SegmentDetectorBenchmark )' "$log" || true
if ! grep -Eq "Test Case .*testSegmentDetectorBenchmark.* passed" "$log"; then
  cat "$log" >&2
  echo "Expected one executed SegmentDetectorBenchmark test." >&2
  exit 1
fi

echo "Benchmark complete."
