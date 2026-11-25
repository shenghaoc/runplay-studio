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
#   ./scripts/check-localization.sh --skip-build --scratch-path <dir> \
#       --stringsdata-dir <dir> --xcode-derived-data <dir>
#                                               # read builds you made yourself
#
# The strings come from two builds. RunPlayCore and RunPlayPlatform are
# SwiftPM targets: their extraction is a `swift build` that passes
# -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path
# -Xswiftc <stringsdata-dir>. RunPlayStudio is the app target of
# RunPlayStudio.xcodeproj: its extraction is the `xcodebuild` build of the
# RunPlayStudio scheme, which emits .stringsdata because the project sets
# SWIFT_EMIT_LOC_STRINGS = YES, under <xcode-derived-data>. The last form is
# how CI avoids a second build of either: it reads the extraction of the
# package build and of the xcodebuild build-for-testing it already ran. The
# checker only looks at sources under each module's Sources directory, so the
# test targets that those builds also compile do not matter.
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
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCH_PATH="$REPO_ROOT/.build-localization"
STRINGSDATA_DIR=""
XCODE_DERIVED_DATA=""
SKIP_BUILD=0
UPDATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE_ARGS=(--update); shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --scratch-path)
      [[ $# -ge 2 ]] || { printf '%s needs a value\n' "$1" >&2; exit 2; }
      SCRATCH_PATH="$(cd "$2" && pwd)" || { printf 'no such directory: %s\n' "$2" >&2; exit 2; }
      shift 2
      ;;
    --stringsdata-dir)
      [[ $# -ge 2 ]] || { printf '%s needs a value\n' "$1" >&2; exit 2; }
      STRINGSDATA_DIR="$(cd "$2" && pwd)" || { printf 'no such directory: %s\n' "$2" >&2; exit 2; }
      shift 2
      ;;
    --xcode-derived-data)
      [[ $# -ge 2 ]] || { printf '%s needs a value\n' "$1" >&2; exit 2; }
      XCODE_DERIVED_DATA="$(cd "$2" && pwd)" || { printf 'no such directory: %s\n' "$2" >&2; exit 2; }
      shift 2
      ;;
    -h|--help)
      sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
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

if [[ -z "$STRINGSDATA_DIR" ]]; then
  STRINGSDATA_DIR="$SCRATCH_PATH/stringsdata"
fi
if [[ -z "$XCODE_DERIVED_DATA" ]]; then
  XCODE_DERIVED_DATA="$SCRATCH_PATH/xcode"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  rm -rf "$STRINGSDATA_DIR"
  mkdir -p "$STRINGSDATA_DIR"
  # Product targets only: tests carry no user-facing strings.
  # swift-build compiles String Catalogs; Swift 6.3.x defaults to the native
  # build system, which does not (the default from Swift 6.4 is swift-build).
  swift build \
    --build-system swiftbuild \
    --package-path "$REPO_ROOT" \
    --scratch-path "$SCRATCH_PATH" \
    -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGSDATA_DIR"
  # Studio's strings: the app target, built as CI builds it.
  xcodebuild build \
    -project "$REPO_ROOT/RunPlayStudio.xcodeproj" \
    -scheme RunPlayStudio \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$XCODE_DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    "$RUNPLAY_XCODEBUILD_PACKAGE_WARNINGS" \
    SWIFT_EMIT_LOC_STRINGS=YES
fi

if [[ "$SKIP_BUILD" -eq 1 ]] \
  && [[ -z "$(find "$STRINGSDATA_DIR" "$SCRATCH_PATH/out" -name '*.stringsdata' -print -quit 2>/dev/null)" ]]; then
  printf 'no .stringsdata under %s or %s/out; build with -emit-localized-strings first\n' \
    "$STRINGSDATA_DIR" "$SCRATCH_PATH" >&2
  exit 2
fi

# Only the app target's own intermediates: xcodebuild also compiles the
# package targets, but their strings come from the SwiftPM build above.
STUDIO_STRINGSDATA=()
while IFS= read -r directory; do
  STUDIO_STRINGSDATA+=(--stringsdata-root "$directory")
done < <(find "$XCODE_DERIVED_DATA/Build/Intermediates.noindex/RunPlayStudio.build" \
  -mindepth 2 -maxdepth 2 -type d -name RunPlayStudio.build 2>/dev/null | LC_ALL=C sort)
if [[ ${#STUDIO_STRINGSDATA[@]} -eq 0 ]]; then
  printf 'no RunPlayStudio intermediates under %s; build the RunPlayStudio scheme with xcodebuild first\n' \
    "$XCODE_DERIVED_DATA" >&2
  exit 2
fi

# SwiftPM's build system may write .stringsdata beside each target's objects
# instead of (or as well as) the requested path; the checker reads both and
# keeps the newest file per source.
python3 "$SCRIPT_DIR/check-localization.py" \
  --repo-root "$REPO_ROOT" \
  --stringsdata-root "$STRINGSDATA_DIR" \
  --stringsdata-root "$SCRATCH_PATH/out" \
  "${STUDIO_STRINGSDATA[@]}" \
  "${UPDATE_ARGS[@]+"${UPDATE_ARGS[@]}"}"
