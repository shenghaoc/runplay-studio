#!/usr/bin/env bash
# check-localization.sh — Fail when a String Catalog is out of step with the
# source, or when a live key lacks a zh-Hans or zh-Hant translation.
#
# Usage:
#   ./scripts/check-localization.sh             # check (CI)
#   ./scripts/check-localization.sh --update    # sync catalogs: add new keys,
#                                               # drop stale ones, then report
#                                               # untranslated keys
#   ./scripts/check-localization.sh --skip-build [--update]
#                                               # reuse the last extraction
#
# The Swift compiler extracts every localizable literal — SwiftUI
# LocalizedStringKey arguments, String(localized:), and the module helpers
# coreLocalized/platformLocalized/studioLocalized, whose parameters are
# String.LocalizationValue — into .stringsdata files when a build passes
# -emit-localized-strings. scripts/check-localization.py then merges them into
# a temporary copy of each module catalog with `xcrun xcstringstool sync`,
# exactly as Xcode would, and compares. The build uses its own scratch path so
# the extraction flags never invalidate the regular .build cache.
#
# macOS only: xcstringstool ships with Xcode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCH_PATH="$REPO_ROOT/.build-localization"
STRINGSDATA_DIR="$SCRATCH_PATH/stringsdata"
SKIP_BUILD=0
UPDATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE_ARGS=(--update); shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown option: %s (use --help)\n' "$1" >&2
      exit 2
      ;;
  esac
done

if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  printf 'xcstringstool not found; check-localization.sh needs Xcode\n' >&2
  exit 2
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  rm -rf "$STRINGSDATA_DIR"
  mkdir -p "$STRINGSDATA_DIR"
  # Product targets only: tests carry no user-facing strings.
  swift build \
    --package-path "$REPO_ROOT" \
    --scratch-path "$SCRATCH_PATH" \
    -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGSDATA_DIR"
fi

# SwiftPM's build system may write .stringsdata beside each target's objects
# instead of (or as well as) the requested path; the checker reads both and
# keeps the newest file per source.
python3 "$SCRIPT_DIR/check-localization.py" \
  --repo-root "$REPO_ROOT" \
  --stringsdata-root "$STRINGSDATA_DIR" \
  --stringsdata-root "$SCRATCH_PATH/out" \
  "${UPDATE_ARGS[@]+"${UPDATE_ARGS[@]}"}"
