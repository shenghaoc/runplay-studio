#!/usr/bin/env bash
#
# Reproducible release benchmark for the combined route-quality geometry cutover.
#
# Reports medians on a deterministic 100,000-point synthetic fixture:
#
#   1. complete Swift stages 2–4 oracle
#   2. complete engine adapter (conversion + engine call + projection)
#   3. complete RouteQualityProcessor.process
#
# It then reports DEM elevation sampling on a 100,000-point route over
# synthetic zoom-12 tiles: the complete adapter (both engine calls, the tile
# hand-off, packing, and translation) and the independent Swift reference
# oracle for context. The timings are absolute.
#
# Debug timings are meaningless here — always release.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release route-quality benchmark..."

# The probe ranges are required. With RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 each
# product-limit probe prints after its report's closing line, so a range
# ending there would run the 1,000,000-point probe and then discard it.
RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter 'RouteQualityPipelineBenchmark|DemElevationSamplingBenchmark' \
  2>&1 | sed -n \
    -e '/RunPlay route-quality geometry benchmark/,/merge gate/p' \
    -e '/product-limit bridge probe/,/peak RSS:/p' \
    -e '/RunPlay DEM elevation sampling benchmark/,/DEM sampling complete/p' \
    -e '/DEM product-limit probe/,/DEM peak RSS:/p'

echo "Benchmark complete."
