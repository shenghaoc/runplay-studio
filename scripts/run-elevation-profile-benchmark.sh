#!/usr/bin/env bash
# run-elevation-profile-benchmark.sh — release ElevationProfile benchmarks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export RUNPLAY_BENCHMARK=1

swift test \
  --configuration release \
  --filter ElevationProfileBenchmark \
  -Xswiftc -warnings-as-errors
