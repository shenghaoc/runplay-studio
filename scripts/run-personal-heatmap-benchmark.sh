#!/usr/bin/env bash
#
# Reproducible release benchmark for personal heatmap route coverage C++23 cutover.
#
# This is the merge gate: complete production builder versus complete Swift
# builder oracle. The extra timings it prints are independent diagnostics and
# are not additive components of the production total; for an additive phase
# decomposition use scripts/run-personal-heatmap-profile.sh.
#

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release personal heatmap coverage benchmark..."

RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter PersonalHeatmapCoverageBenchmark \
  2>&1 | sed -n '/RunPlay personal heatmap route coverage benchmark/,/run-personal-heatmap-profile/p'

echo "Benchmark complete."
