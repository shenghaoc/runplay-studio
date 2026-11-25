#!/usr/bin/env bash
#
# Reproducible release benchmark for the combined route-quality geometry kernel.
#
# Reports medians on a deterministic 100,000-point synthetic fixture:
#
#   1. complete engine adapter (conversion + engine call + projection)
#   2. complete RouteQualityProcessor.process
#
# It then reports DEM elevation sampling on a 100,000-point route over
# synthetic zoom-12 tiles: the complete adapter (both engine calls, the tile
# hand-off, packing, and translation).
#
# Each case prints one stable line, "<Benchmark> <case> <count>=<value> ...
# iterations=<n> swift_ms=<median>". The timings are an absolute Swift
# baseline with no ratio gate.
#
# Debug timings are meaningless here — always release.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release route-quality benchmark..."

# Selecting the baseline lines by prefix keeps the product-limit lines too:
# with RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 they print after each report header.
RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter 'RouteQualityPipelineBenchmark|DemElevationSamplingBenchmark' \
  2>&1 | grep -E '^(RunPlay route-quality geometry benchmark|RunPlay DEM elevation sampling benchmark|RouteQualityPipelineBenchmark |DemElevationSamplingBenchmark )'

echo "Benchmark complete."
