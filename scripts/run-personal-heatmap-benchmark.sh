#!/usr/bin/env bash
#
# Reproducible release benchmarks for the complete Personal Heatmap builder and
# isolated Swift cross-workout aggregation.
#
# The timings are an absolute Swift baseline with no ratio gate. Each engine
# case prints one stable line, "<Benchmark> <case> <count>=<value> ...
# iterations=<n> swift_ms=<median>". The extra coverage-benchmark timings are
# independent diagnostics and are not additive components of the builder
# total; for an additive phase decomposition use
# scripts/run-personal-heatmap-profile.sh.
#

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

log="$(mktemp "${TMPDIR:-/tmp}/runplay-heatmap-benchmark.XXXXXX")"
trap 'rm -f "$log"' EXIT

echo "Building and running the release personal heatmap benchmarks..." >&2

status=0
RUNPLAY_BENCHMARK=1 \
RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1 \
swift test \
  -c release \
  --filter 'PersonalHeatmapCoverageBenchmark|PersonalHeatmapAggregationBenchmark|PersonalHeatmapEngineBenchmark' \
  > "$log" 2>&1 || status=$?

for marker in \
  'BEGIN RUNPLAY HEATMAP COVERAGE BENCHMARK' \
  'BEGIN RUNPLAY HEATMAP AGGREGATION BENCHMARK' \
  'BEGIN RUNPLAY HEATMAP ENGINE BENCHMARK'; do
  if ! grep -q "$marker" "$log"; then
    echo "run-personal-heatmap-benchmark: missing report marker: $marker" >&2
    tail -80 "$log" >&2
    [[ $status -eq 0 ]] && status=1
    exit "$status"
  fi
done

sed -n \
  '/BEGIN RUNPLAY HEATMAP COVERAGE BENCHMARK/,/END RUNPLAY HEATMAP COVERAGE BENCHMARK/p' \
  "$log" | grep -v 'RUNPLAY HEATMAP COVERAGE BENCHMARK'

sed -n \
  '/BEGIN RUNPLAY HEATMAP AGGREGATION BENCHMARK/,/END RUNPLAY HEATMAP AGGREGATION BENCHMARK/p' \
  "$log" | grep -v 'RUNPLAY HEATMAP AGGREGATION BENCHMARK'

# The complete engine path: one HEATMAP_ENGINE line (Swift median) per fixture.
sed -n \
  '/BEGIN RUNPLAY HEATMAP ENGINE BENCHMARK/,/END RUNPLAY HEATMAP ENGINE BENCHMARK/p' \
  "$log" | grep -v 'RUNPLAY HEATMAP ENGINE BENCHMARK'

if [[ $status -ne 0 ]]; then
  echo "" >&2
  echo "run-personal-heatmap-benchmark: benchmark FAILED." >&2
  grep -E 'error:|XCTAssert|failed|diverged' "$log" | head -40 >&2
  exit "$status"
fi

echo "" >&2
echo "Benchmarks complete." >&2
