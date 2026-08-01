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
# Debug timings are meaningless here — always release.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release route-quality benchmark..."

# The second range is required. With RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1 the
# product-limit probe prints after the "merge gate" line, so a single range
# ending there runs the 1,000,000-point probe and then discards its report.
RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter RouteQualityPipelineBenchmark \
  2>&1 | sed -n \
    -e '/RunPlay route-quality geometry benchmark/,/merge gate/p' \
    -e '/product-limit native probe/,/peak RSS:/p'

echo "Benchmark complete."
