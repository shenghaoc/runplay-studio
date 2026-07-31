#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Remaining Core Hotspot Profile ==="
echo "Family: ${RUNPLAY_PROFILE_FAMILY:-all}"
echo "Product Limit: ${RUNPLAY_PROFILE_PRODUCT_LIMIT:-0}"
echo

# Build in release mode for representative timings
echo "--- Building RunPlayCore in release ---"
swift build --target RunPlayEngineCpp \
  -Xcxx -Wall -Xcxx -Wextra -Xcxx -Wpedantic \
  -Xcxx -Wconversion -Xcxx -Wsign-conversion -Xcxx -Wshadow \
  --configuration release 2>&1 | tail -5

# Run just the profile test
echo
echo "--- Running profile ---"
export RUNPLAY_CORE_HOTSPOT_PROFILE=1
export RUNPLAY_PROFILE_FAMILY="${RUNPLAY_PROFILE_FAMILY:-all}"
export RUNPLAY_PROFILE_PRODUCT_LIMIT="${RUNPLAY_PROFILE_PRODUCT_LIMIT:-0}"

swift test --filter RemainingCoreHotspotProfile --configuration release \
  -Xswiftc -warnings-as-errors 2>&1

echo
echo "=== Done ==="
