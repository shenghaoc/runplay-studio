#!/usr/bin/env bash
#
# Reproducible release benchmark for personal heatmap route coverage C++23 cutover.
#

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release personal heatmap coverage benchmark..."

RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter PersonalHeatmapCoverageBenchmark \
  2>&1 | sed -n '/RunPlay personal heatmap route coverage benchmark/,/merge gate/p'

echo "Benchmark complete."
