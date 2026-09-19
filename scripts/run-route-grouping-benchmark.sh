#!/usr/bin/env bash
# Route-grouping benchmark: stage-1 candidate filtering versus brute-force
# all-pairs matching on a 2,000-workout synthetic library.
#
# Prints the report section between the BEGIN/END RUNPLAY ROUTE GROUPING
# BENCHMARK markers emitted by the env-gated benchmark test. Never run in CI.
set -euo pipefail

cd "$(dirname "$0")/.."

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

RUNPLAY_ROUTE_GROUPING_BENCHMARK=1 swift test -c release \
  --filter RouteGroupingBenchmark 2>&1 | tee "$LOG" >/dev/null

if ! grep -q "BEGIN RUNPLAY ROUTE GROUPING BENCHMARK" "$LOG"; then
  echo "route-grouping benchmark: no report found in test output" >&2
  exit 1
fi

sed -n '/BEGIN RUNPLAY ROUTE GROUPING BENCHMARK/,/END RUNPLAY ROUTE GROUPING BENCHMARK/p' "$LOG"
