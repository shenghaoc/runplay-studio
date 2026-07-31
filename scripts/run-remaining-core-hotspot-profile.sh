#!/usr/bin/env bash
#
# Release phase-level profile of remaining RunPlayCore computational hotspots.
#
# Prints Markdown-compatible reports from Core and Platform harnesses.
# Ordinary CI never sets RUNPLAY_CORE_HOTSPOT_PROFILE, so these tests skip there.
#
# Environment:
#   RUNPLAY_PROFILE_FAMILY=all|analysis|alignment|metrics|import|comparison
#   RUNPLAY_PROFILE_PRODUCT_LIMIT=1   # enable 1M-point probes
#   RUNPLAY_PROFILE_MEMORY=1         # extra memory reporting
#

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAMILY="${RUNPLAY_PROFILE_FAMILY:-all}"
PRODUCT_LIMIT="${RUNPLAY_PROFILE_PRODUCT_LIMIT:-0}"
MEMORY="${RUNPLAY_PROFILE_MEMORY:-0}"

log="$(mktemp "${TMPDIR:-/tmp}/runplay-core-hotspot-profile.XXXXXX")"
trap 'rm -f "$log"' EXIT

echo "=== Remaining Core Hotspot Profile ===" >&2
echo "Family: ${FAMILY}" >&2
echo "Product limit: ${PRODUCT_LIMIT}" >&2
echo "Memory mode: ${MEMORY}" >&2
echo >&2

export RUNPLAY_CORE_HOTSPOT_PROFILE=1
export RUNPLAY_PROFILE_FAMILY="$FAMILY"
export RUNPLAY_PROFILE_PRODUCT_LIMIT="$PRODUCT_LIMIT"
export RUNPLAY_PROFILE_MEMORY="$MEMORY"

status=0

echo "--- Building and running Core profile (release) ---" >&2
swift test \
  -c release \
  --filter RemainingCoreHotspotProfile \
  -Xswiftc -warnings-as-errors \
  > "$log" 2>&1 || status=$?

if ! grep -q 'BEGIN RUNPLAY CORE HOTSPOT PROFILE' "$log"; then
  # Family filter may legitimately emit nothing if only Platform families match,
  # but Core always has at least the invocation-counter test. Treat missing
  # report as failure only when family expects Core output.
  case "$FAMILY" in
    all|analysis|alignment|metrics|import|comparison)
      echo "run-remaining-core-hotspot-profile: no Core profile report was emitted." >&2
      tail -120 "$log" >&2
      [[ $status -eq 0 ]] && status=1
      ;;
  esac
fi

# Emit Core report sections (preserve compiler/test failure context on failure).
if grep -q 'BEGIN RUNPLAY CORE HOTSPOT PROFILE' "$log"; then
  sed -n '/BEGIN RUNPLAY CORE HOTSPOT PROFILE/,/END RUNPLAY CORE HOTSPOT PROFILE/p' "$log"
fi

if [[ $status -ne 0 ]]; then
  echo "" >&2
  echo "run-remaining-core-hotspot-profile: Core profile FAILED." >&2
  grep -E 'error:|XCTAssert|failed|diverged|accounting residue|mismatch' "$log" | head -60 >&2
  exit "$status"
fi

# Platform profile (map lines / Strava) — macOS only; ignore when target absent.
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "" >&2
  echo "--- Running Platform profile (release, skip-build when possible) ---" >&2
  plat_log="$(mktemp "${TMPDIR:-/tmp}/runplay-platform-hotspot-profile.XXXXXX")"
  plat_status=0
  swift test \
    -c release \
    --filter RemainingPlatformHotspotProfile \
    -Xswiftc -warnings-as-errors \
    > "$plat_log" 2>&1 || plat_status=$?

  if grep -q 'BEGIN RUNPLAY PLATFORM HOTSPOT PROFILE' "$plat_log"; then
    sed -n '/BEGIN RUNPLAY PLATFORM HOTSPOT PROFILE/,/END RUNPLAY PLATFORM HOTSPOT PROFILE/p' "$plat_log"
  fi

  if [[ $plat_status -ne 0 ]]; then
    echo "" >&2
    echo "run-remaining-core-hotspot-profile: Platform profile FAILED." >&2
    tail -120 "$plat_log" >&2
    grep -E 'error:|XCTAssert|failed' "$plat_log" | head -40 >&2
    rm -f "$plat_log"
    exit "$plat_status"
  fi
  rm -f "$plat_log"
fi

echo "" >&2
echo "=== Profile complete ===" >&2
exit 0
