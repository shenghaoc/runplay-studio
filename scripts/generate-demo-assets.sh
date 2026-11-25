#!/usr/bin/env bash
# generate-demo-assets.sh — Render the README demo media from the bundled
# synthetic sample runs through the app's offline export pipeline. Nothing is
# screen-recorded: a debug build of the app runs headless (--demo-assets) and
# calls the same PNG and video exporters as the export sheets.
#
# Usage:
#   ./scripts/generate-demo-assets.sh [--output-dir <dir>] [--skip-build]
#
# The default mode writes into <dir> (default .build/demo-assets):
#   demo-summary-{light,dark}.png            PNG summary card, exactly 1200×1600
#   demo-route-replay-{light,dark}.mp4       Route Replay, 1920×1080, 30 fps, 15 s
#   demo-comparison-replay-{light,dark}.mp4  Comparison Replay (Route-Aware), same contract
#   demo-route-replay-{light,dark}.gif       7.5 s loop derived from each Route Replay MP4
#   demo-route-replay-{light,dark}-poster.png  Static first frame of each replay
#   demo-assets-provenance.txt               macOS and Xcode versions used
#   SHA256SUMS
#
# The curated set a docs/assets refresh would commit (the summary cards, the
# GIFs and posters, and the provenance file) must fit the size budget below;
# generation fails when it does not. The script is a local tool and a manual
# workflow, never part of CI.
#
# A relative --output-dir is resolved from the current directory. Inside the
# repository only descendants of .build/ (which git ignores) are accepted, so the script never
# writes to docs/assets/ and generated media cannot be committed by accident.
# Refreshing the committed media is a reviewed change; see docs/demo-assets.md.
#
# Requirements: macOS with Xcode's Swift toolchain; network access for the
# MapKit basemaps (videos only); Python 3 for safe path canonicalization.
#
# Exit status: 0 success; 1 the curated set is over the size budget; 2 any
# other failure; 64 usage error.

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# docs/assets/ size budget in bytes, enforced on the generated curated set.
# Every committed byte
# stays in clone history across refreshes, so the budget fits the curated set
# (two summary cards near 120 KB and two GIFs near 2.7 MB) with modest
# headroom. The MP4s (about 12 MB each) are workflow artifacts, never committed.
MAX_FILE_BYTES=3000000
MAX_TOTAL_BYTES=7000000

# Records what rendered the media: text rasterization can change between
# macOS builds, so a refresh commits this file with the cards.
PROVENANCE_FILE="demo-assets-provenance.txt"

# Marks an output directory as this script's, so a rerun may clear it.
OUTPUT_MARKER=".runplay-demo-assets"

log() { echo "generate-demo-assets: $*" >&2; }
die() { log "error: $*"; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  generate-demo-assets.sh [--output-dir <dir>] [--skip-build]

Render the README demo media from the bundled synthetic sample runs.

Options:
  --output-dir <dir>  Where to write (default .build/demo-assets); it must
                      resolve to a strict descendant of .build/
  --skip-build        Reuse the existing debug build
  -h, --help          Show this help

Never writes to docs/assets/ and never commits; see docs/demo-assets.md.
EOF
}

# Resolve existing symlink ancestors, even when the last component does not
# exist. Do not rely on lexical normalization, which changes link/.. meaning.
resolve_output_dir() {
  python3 - "$REPO_ROOT" "$1" <<'PYTHON'
import os
import sys

repo = os.path.realpath(sys.argv[1])
root = os.path.join(repo, ".build")
target = os.path.realpath(sys.argv[2])
if os.path.realpath(root) != root or not target.startswith(root + os.sep):
    sys.exit(f"{target} must resolve to a strict descendant of {root}")
print(target)
PYTHON
}

OUTPUT_DIR=""
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 64; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "unknown option: $1"
      usage >&2
      exit 64
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] \
  || die "the demo media render through AppKit, SwiftUI, and MapKit; run this on macOS"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$REPO_ROOT/.build/demo-assets"
fi
# Resolve before the cd below, so a relative path means what the caller meant.
OUTPUT_DIR="$(resolve_output_dir "$OUTPUT_DIR")" || die "unsafe --output-dir"

file_size() {
  stat -f %z "$1"
}

# Create the output directory, or clear what an earlier run of this script
# wrote there. A non-empty directory without the marker is refused, so a
# mistyped --output-dir can never delete someone's files.
prepare_output_dir() {
  local dir="$1"
  if [[ -e "$dir" ]]; then
    [[ -d "$dir" ]] || die "$dir exists and is not a directory"
    [[ ! -L "$dir/$OUTPUT_MARKER" ]] || die "$dir has a symbolic-link output marker"
    if [[ ! -f "$dir/$OUTPUT_MARKER" && -n "$(ls -A "$dir")" ]]; then
      die "$dir is not empty and was not created by this script; choose another --output-dir"
    fi
    rm -f "$dir"/demo-*.png "$dir"/demo-*.mp4 "$dir"/demo-*.gif \
      "$dir/$PROVENANCE_FILE" "$dir/SHA256SUMS" \
      || die "could not clear the previous output in $dir"
  fi
  mkdir -p "$dir" || die "could not create $dir"
  if [[ ! -f "$dir/$OUTPUT_MARKER" ]]; then
    (set -C; : > "$dir/$OUTPUT_MARKER") || die "could not write to $dir"
  fi
}

write_provenance() {
  {
    echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  } > "$OUTPUT_DIR/$PROVENANCE_FILE" || die "could not write $PROVENANCE_FILE"
}

cd "$REPO_ROOT"

# Debug build: the app's --demo-assets mode exists only in debug builds. The
# app is the RunPlayStudio target of RunPlayStudio.xcodeproj; its derived data
# lives under the git-ignored .build/.
DERIVED_DATA="$REPO_ROOT/.build/xcode"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "building RunPlayStudio (debug)..."
  xcodebuild build \
    -project "$REPO_ROOT/RunPlayStudio.xcodeproj" \
    -scheme RunPlayStudio \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    "$RUNPLAY_XCODEBUILD_PACKAGE_WARNINGS" \
    >&2 || die "xcodebuild build failed"
fi
APP="$DERIVED_DATA/Build/Products/Debug/RunPlayStudio.app/Contents/MacOS/RunPlayStudio"
[[ -x "$APP" ]] || die "no debug RunPlayStudio binary at $APP; rerun without --skip-build"

OUTPUT_DIR="$(resolve_output_dir "$OUTPUT_DIR")" || die "unsafe --output-dir"
prepare_output_dir "$OUTPUT_DIR"
write_provenance

# Every implicit input the renderer reads, pinned: the card's date line
# (locale, time zone), MapKit label language, and Swift's Hasher seed. The app
# refuses to render without them (DemoAssetEnvironment).
render() {
  env TZ=UTC SWIFT_DETERMINISTIC_HASHING=1 \
    "$APP" -AppleLocale en_US -AppleLanguages '(en-US)' \
    --demo-assets render --output-dir "$OUTPUT_DIR" --only "$1"
}

# Report every file over the per-file budget and a total over the overall
# budget for the given files; returns 1 when anything is over.
check_budget() {
  local label="$1"
  shift
  local status=0 total=0 file size
  for file in "$@"; do
    size="$(file_size "$file")"
    total=$((total + size))
    if (( size > MAX_FILE_BYTES )); then
      log "$label: $(basename "$file") is $size bytes, over the $MAX_FILE_BYTES-byte per-file budget"
      status=1
    fi
  done
  if (( total > MAX_TOTAL_BYTES )); then
    log "$label: $total bytes in total, over the $MAX_TOTAL_BYTES-byte budget"
    status=1
  else
    log "$label: $total of $MAX_TOTAL_BYTES budget bytes"
  fi
  return "$status"
}

generate() {
  render all || die "rendering failed"
  (cd "$OUTPUT_DIR" && shasum -a 256 demo-* > SHA256SUMS) || die "could not write SHA256SUMS"

  log "output in $OUTPUT_DIR:"
  local file
  for file in "$OUTPUT_DIR"/demo-*; do
    printf '  %-36s %10s bytes\n' "$(basename "$file")" "$(file_size "$file")" >&2
  done

  # The curated set a docs/assets refresh would commit.
  # ${a[@]+"${a[@]}"} keeps an empty array legal under set -u on bash 3.2.
  local curated=(
    "$OUTPUT_DIR"/demo-summary-*.png
    "$OUTPUT_DIR"/demo-route-replay-*.gif
    "$OUTPUT_DIR"/demo-route-replay-*-poster.png
    "$OUTPUT_DIR/$PROVENANCE_FILE"
  )
  if ! check_budget "curated set (summary PNGs, route GIFs and posters, provenance)" ${curated[@]+"${curated[@]}"}; then
    log "error: this output does not fit the docs/assets budget; it cannot be committed as is (docs/demo-assets.md)"
    exit 1
  fi
}

generate
