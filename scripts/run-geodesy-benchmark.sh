#!/usr/bin/env bash
# Release scalar geodesy comparison; no production engine call path has switched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RUNPLAY_BENCHMARK=1 ./scripts/retry-swiftpm-libdispatch-crash.sh swift test \
  -c release \
  --filter 'RunPlayGeodesyBridgeTests.testSwiftEngineGeodesyKernelBenchmark'
