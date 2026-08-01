#!/usr/bin/env bash
# Reproducible release benchmark for the complete SegmentDetector cutover.
#
# Set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 to add the one-million-point probe.
# Timings are reported for evidence; only exact durable highlight parity is an
# assertion. Ordinary CI skips the benchmark.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release SegmentDetector benchmark..."

RUNPLAY_BENCHMARK=1 \
RUNPLAY_BENCHMARK_PRODUCT_LIMIT="${RUNPLAY_BENCHMARK_PRODUCT_LIMIT:-0}" \
swift test \
  -c release \
  --filter SegmentDetectorBenchmark \
  2>&1 | sed -n '/RunPlay SegmentDetector benchmark/,/semantic merge gate/p'

echo "Benchmark complete."
