#!/usr/bin/env bash
# Release benchmark for the C++23 route-metric numeric finalizer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export RUNPLAY_BENCHMARK=1
export RUNPLAY_BENCHMARK_PRODUCT_LIMIT="${RUNPLAY_BENCHMARK_PRODUCT_LIMIT:-0}"

log="$(mktemp "${TMPDIR:-/tmp}/runplay-route-metric-benchmark.XXXXXX")"
platform_log="$(mktemp "${TMPDIR:-/tmp}/runplay-route-metric-platform.XXXXXX")"
cleanup() { rm -f "$log" "$platform_log"; }
trap cleanup EXIT

swift test -c release \
  --filter RouteMetricScaleBucketBenchmark \
  -Xswiftc -warnings-as-errors >"$log" 2>&1

if ! grep -q 'BEGIN RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK' "$log"; then
  tail -120 "$log" >&2
  echo "route metric benchmark report missing" >&2
  exit 1
fi
sed -n '/BEGIN RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK/,/END RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK/p' "$log"

if [[ "$(uname -s)" == "Darwin" ]]; then
  RUNPLAY_CORE_HOTSPOT_PROFILE=1 \
  RUNPLAY_PROFILE_FAMILY=metrics \
  swift test -c release \
    --filter RemainingPlatformHotspotProfile \
    -Xswiftc -warnings-as-errors >"$platform_log" 2>&1
  sed -n '/BEGIN RUNPLAY PLATFORM HOTSPOT PROFILE LINES/,/END RUNPLAY PLATFORM HOTSPOT PROFILE LINES/p' "$platform_log"
fi
