#!/usr/bin/env bash
#
# Reproducible release benchmark for the route step-distance cutover.
#
# Reports three medians on a deterministic 100,000-point synthetic fixture:
#
#   1. the pure Swift step loop the cutover replaces
#   2. the complete bridge, including RouteInputSample conversion
#   3. RouteQualityProcessor.process, the production operation replaced
#
# Measurement 3 is the merge gate. Measurement 2 is the fixed per-call boundary
# tax and is expected to exceed measurement 1; see docs/phase-plan.md.
#
# The benchmark is skipped by ordinary test runs, so no wall-clock assertion
# ever reaches CI. Debug timings are meaningless here — always release.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building and running the release benchmark (this takes a minute)..."

RUNPLAY_BENCHMARK=1 swift test \
  -c release \
  --filter RouteStepDistanceBenchmark \
  2>&1 | sed -n '/RunPlay route step-distance benchmark/,/fixed per-call boundary tax/p'

echo "Benchmark complete."
