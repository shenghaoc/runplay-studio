#!/usr/bin/env bash
# Release timing of the scalar engine geodesy primitives (no production caller).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RUNPLAY_BENCHMARK=1 ./scripts/retry-swiftpm-libdispatch-crash.sh swift test \
  -c release \
  --filter 'RunPlayGeodesyBridgeTests.testSwiftEngineGeodesyKernelBenchmark'
