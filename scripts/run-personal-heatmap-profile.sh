#!/usr/bin/env bash
#
# Reproducible release phase-level profile of the Personal Heatmap pipeline.
#
# Prints a Markdown-compatible report and exits nonzero when the profile's
# snapshot parity assertions or the build itself fail. This is a local
# profiling tool; ordinary CI never sets RUNPLAY_HEATMAP_PROFILE, so the test
# skips there.
#
# Detailed phase attribution lives here. scripts/run-personal-heatmap-benchmark.sh
# remains the historical complete-builder-versus-Swift-oracle merge gate.
#

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

log="$(mktemp "${TMPDIR:-/tmp}/runplay-heatmap-profile.XXXXXX")"
trap 'rm -f "$log"' EXIT

echo "Building and running the release personal heatmap pipeline profile..." >&2

status=0
RUNPLAY_HEATMAP_PROFILE=1 swift test \
  -c release \
  --filter PersonalHeatmapPipelineProfile \
  > "$log" 2>&1 || status=$?

if ! grep -q 'BEGIN RUNPLAY HEATMAP PROFILE' "$log"; then
  echo "run-personal-heatmap-profile: no profile report was emitted." >&2
  tail -80 "$log" >&2
  exit "${status:-1}"
fi

sed -n '/BEGIN RUNPLAY HEATMAP PROFILE/,/END RUNPLAY HEATMAP PROFILE/p' "$log" \
  | grep -v 'RUNPLAY HEATMAP PROFILE'

if [[ $status -ne 0 ]]; then
  echo "" >&2
  echo "run-personal-heatmap-profile: profile FAILED (parity or validation)." >&2
  grep -E 'error:|XCTAssert|failed|diverged' "$log" | head -40 >&2
  exit "$status"
fi

echo "" >&2
echo "Profile complete." >&2
