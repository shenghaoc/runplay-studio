#!/usr/bin/env bash
#
# Reproducible release benchmark for the combined route-quality geometry cutover.
#
# Reports medians on a deterministic 100,000-point synthetic fixture:
#
#   1. complete Swift stages 2–4 oracle
#   2. complete combined bridge (conversion + C++ + projection)
#   3. native combined kernel alone (diagnostic)
#   4. complete RouteQualityProcessor.process
#
# The primary merge gate is measurement 2 versus measurement 1.
#
# It then reports DEM elevation sampling on a 100,000-point route over
# synthetic zoom-12 tiles: the complete bridge (both native calls, the tile
# hand-off, packing, and translation), each phase, and the independent Swift
# reference oracle for context. DEM sampling has no Swift production path to
# gate against; the report tracks its cost on the route boundary.
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
    -e '/product-limit native probe/,/peak RSS:/p' \
    -e '/RunPlay DEM elevation sampling benchmark/,/DEM sampling complete/p' \
    -e '/DEM product-limit probe/,/DEM peak RSS:/p'

echo "Benchmark complete."
