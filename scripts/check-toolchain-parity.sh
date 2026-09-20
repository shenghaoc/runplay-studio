#!/usr/bin/env bash
# check-toolchain-parity.sh — fail unless the local Swift toolchain's
# marketing version matches the Linux container image pinned in
# .github/workflows/ci.yml.
#
# Why this exists: the macOS runner image rolls its single Xcode forward on
# its own, and Xcode releases change the bundled Swift marketing version
# (Xcode 26.6 shipped Swift 6.3.3 while Xcode 27.0 ships 6.4). The Linux
# side pins its toolchain by container image. Without a comparison, the two
# platforms can silently drift apart — macOS testing one Swift version
# while Linux tests another — which is exactly the divergence this
# repository's dual-platform CI exists to prevent.
#
# Resolution: full marketing versions are compared numerically, with a
# missing patch component treated as .0, because the two sides print
# differently — Apple's swift reports "Apple Swift version 6.4" (patch
# appears only when nonzero, e.g. 6.3.3) while the container pin carries
# "6.4.0". So 6.4 and 6.4.0 compare equal, and an Xcode point release that
# moves Swift 6.4 -> 6.4.2 DOES trip the gate: every macOS job fails until
# the container image is bumped to the matching version. Consequence
# accepted by policy — better a red CI than two platforms testing two
# toolchains.
#
# The container image tag in ci.yml is the single source of truth for the
# expected version (GitHub Actions cannot expand env context inside the
# `container:` key, so the literal there is the only copy). This script
# reads that literal back out of the checked-out workflow file — which is
# why every job that runs this script must do a full actions/checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/ci.yml"

# Print a version as a numeric major.minor.patch triple; a missing
# component counts as 0. Bash 3.2-safe (macOS /bin/bash).
normalize_version() {
  local a b c
  IFS=. read -r a b c <<<"$1"
  printf '%s.%s.%s' "${a:-0}" "${b:-0}" "${c:-0}"
}

EXPECTED="$(grep -oE 'container:[[:space:]]*swift:[0-9]+(\.[0-9]+)+' "${WORKFLOW}" | head -n1 | grep -oE '[0-9]+(\.[0-9]+)+' | tail -n1)"
if [[ -z "${EXPECTED}" ]]; then
  echo "check-toolchain-parity: no 'container: swift:<version>' pin found in ${WORKFLOW}" >&2
  exit 1
fi

ACTUAL="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+(\.[0-9]+)+' | head -n1 | grep -oE '[0-9]+(\.[0-9]+)+' | tail -n1)"
if [[ -z "${ACTUAL}" ]]; then
  echo "check-toolchain-parity: could not read a Swift marketing version from 'swift --version'" >&2
  swift --version >&2 || true
  exit 1
fi

echo "local Swift marketing version:  ${ACTUAL}"
echo "Linux container image declares: ${EXPECTED} (${WORKFLOW})"

if [[ "$(normalize_version "${ACTUAL}")" != "$(normalize_version "${EXPECTED}")" ]]; then
  echo "check-toolchain-parity: Swift toolchains diverged — macOS-side swift is ${ACTUAL} while the Linux container pin is ${EXPECTED}." >&2
  echo "Bump the container image in ci.yml (or the macOS runner image) so both platforms test the same Swift version." >&2
  exit 1
fi
