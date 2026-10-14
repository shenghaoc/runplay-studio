#!/usr/bin/env bash
# generate-demo-assets.sh — Render the README demo media from the bundled
# synthetic sample runs through the app's offline export pipeline. Nothing is
# screen-recorded: a debug build of the app runs headless (--demo-assets) and
# calls the same PNG and video exporters as the export sheets.
#
# Usage:
#   ./scripts/generate-demo-assets.sh [--output-dir <dir>] [--skip-build] [--skip-gif]
#   ./scripts/generate-demo-assets.sh --check [--output-dir <dir>] [--skip-build]
#
# The default mode writes into <dir> (default .build/demo-assets):
#   demo-summary-{light,dark}.png            PNG summary card, exactly 1200×1600
#   demo-route-replay-{light,dark}.mp4       Route Replay, 1920×1080, 30 fps, 15 s
#   demo-comparison-replay-{light,dark}.mp4  Comparison Replay (Route-Aware), same contract
#   demo-route-replay-{light,dark}.gif       7.5 s loop derived from each Route Replay MP4
#   demo-assets-provenance.txt               macOS, Xcode, and ffmpeg versions used
#   SHA256SUMS
#
# --check renders only the summary cards, compares each with its committed
# copy in docs/assets/ within the pixel tolerance in
# RunPlayStudio/Sources/DemoAssets/DemoAssetImageComparison.swift, and
# enforces the docs/assets/ size budget below. It is the CI drift gate.
#
# A relative --output-dir is resolved from the current directory. Inside the
# repository only .build/ (which git ignores) is accepted, so the script never
# writes to docs/assets/ and generated media cannot be committed by accident.
# Refreshing the committed media is a reviewed change; see docs/demo-assets.md.
#
# Requirements: macOS with Xcode's Swift toolchain; network access for the
# MapKit basemaps (videos only); ffmpeg on PATH for the GIF step.
#
# Exit status: 0 success; 1 drift or budget failure (--check only); 2 any
# other failure; 64 usage error.

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$REPO_ROOT/docs/assets"

# docs/assets/ size budget in bytes, enforced by --check. Every committed byte
# stays in clone history across refreshes, so the budget fits the curated set
# (two summary cards near 120 KB and two GIFs near 2.7 MB) with modest
# headroom. The MP4s (about 12 MB each) are workflow artifacts, never committed.
MAX_FILE_BYTES=3000000
MAX_TOTAL_BYTES=7000000

# The GIF step, documented in docs/demo-assets.md: 2× playback so the whole
# 15 s replay loops in 7.5 s, 10 fps, 720 px wide, one 256-colour palette from
# every frame, no dithering (the flat map colours need none), and only the
# changed rectangle stored per frame. For one input MP4 and one ffmpeg build
# the output is byte-identical.
GIF_FILTER='setpts=0.5*PTS,fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle'

# Records what rendered the media. Text rasterization can change between
# macOS builds, so --check reports the build behind the committed cards next
# to its own.
PROVENANCE_FILE="demo-assets-provenance.txt"

# Marks an output directory as this script's, so a rerun may clear it.
OUTPUT_MARKER=".runplay-demo-assets"

log() { echo "generate-demo-assets: $*" >&2; }
die() { log "error: $*"; exit 2; }

# A GitHub Actions annotation (workflow commands are read from stdout), so a
# CI run names the cause on its summary page; a no-op elsewhere.
annotate() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
  echo "::$1 title=$2::$3"
}

usage() {
  cat <<'EOF'
Usage:
  generate-demo-assets.sh [--output-dir <dir>] [--skip-build] [--skip-gif]
  generate-demo-assets.sh --check [--output-dir <dir>] [--skip-build]

Render the README demo media from the bundled synthetic sample runs.

Options:
  --check             Render the summary cards only and compare them with
                      docs/assets/ (the CI drift gate); also enforce the
                      docs/assets/ size budget
  --output-dir <dir>  Where to write (default .build/demo-assets, or
                      .build/demo-assets-check with --check); inside the
                      repository it must be under .build/
  --skip-build        Reuse the existing debug build
  --skip-gif          Skip the ffmpeg GIF step
  -h, --help          Show this help

Never writes to docs/assets/ and never commits; see docs/demo-assets.md.
EOF
}

# An absolute path with "." and ".." resolved lexically; symlinks are left
# alone. Splitting with read keeps path components out of glob expansion.
normalize_path() {
  local path="$1" part
  local parts=() kept=()
  [[ "$path" == /* ]] || path="$PWD/$path"
  IFS=/ read -r -a parts <<< "$path"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ""|.) ;;
      ..)
        if [[ ${#kept[@]} -gt 0 ]]; then
          unset "kept[$((${#kept[@]} - 1))]"
        fi
        ;;
      *) kept+=("$part") ;;
    esac
  done
  local IFS=/
  printf '/%s\n' "${kept[*]-}"
}

MODE="generate"
OUTPUT_DIR=""
SKIP_BUILD=0
SKIP_GIF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 64; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-gif)
      SKIP_GIF=1
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

if [[ "$MODE" == "check" && "$SKIP_GIF" -eq 1 ]]; then
  log "--skip-gif has no effect with --check"
fi

[[ "$(uname -s)" == "Darwin" ]] \
  || die "the demo media render through AppKit, SwiftUI, and MapKit; run this on macOS"

if [[ -z "$OUTPUT_DIR" ]]; then
  if [[ "$MODE" == "check" ]]; then
    OUTPUT_DIR="$REPO_ROOT/.build/demo-assets-check"
  else
    OUTPUT_DIR="$REPO_ROOT/.build/demo-assets"
  fi
fi
# Resolve before the cd below, so a relative path means what the caller meant.
OUTPUT_DIR="$(normalize_path "$OUTPUT_DIR")"
case "$OUTPUT_DIR" in
  "$REPO_ROOT/.build"|"$REPO_ROOT/.build/"*) ;;
  "$REPO_ROOT"|"$REPO_ROOT/"*)
    die "$OUTPUT_DIR is inside the repository but not under .build/; generated media there could be committed by accident"
    ;;
esac

# Fail before any build or render when the GIF step cannot run.
if [[ "$MODE" == "generate" && "$SKIP_GIF" -eq 0 ]] && ! command -v ffmpeg >/dev/null 2>&1; then
  die "ffmpeg is required for the GIF step and was not found on PATH; install it (for example 'brew install ffmpeg') or rerun with --skip-gif"
fi

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
    if [[ ! -e "$dir/$OUTPUT_MARKER" && -n "$(ls -A "$dir")" ]]; then
      die "$dir is not empty and was not created by this script; choose another --output-dir"
    fi
    rm -f "$dir"/demo-*.png "$dir"/demo-*.mp4 "$dir"/demo-*.gif \
      "$dir/$PROVENANCE_FILE" "$dir/SHA256SUMS" \
      || die "could not clear the previous output in $dir"
  fi
  mkdir -p "$dir" || die "could not create $dir"
  : > "$dir/$OUTPUT_MARKER" || die "could not write to $dir"
}

write_provenance() {
  {
    echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [[ "$MODE" == "generate" && "$SKIP_GIF" -eq 0 ]]; then
      echo "ffmpeg: $(ffmpeg -version | sed -n 1p)"
    fi
  } > "$OUTPUT_DIR/$PROVENANCE_FILE" || die "could not write $PROVENANCE_FILE"
}

# The value of one "key: value" line of a provenance file; empty if absent.
provenance_value() {
  [[ -f "$2" ]] || return 0
  sed -n "s/^$1: //p" "$2" | sed -n 1p
}

cd "$REPO_ROOT"

# Debug build with CI's flags: the app's --demo-assets mode exists only in
# debug builds, and matching `swift test -Xswiftc -warnings-as-errors` lets
# the CI check reuse that job's build instead of compiling again.
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "building RunPlayStudio (debug)..."
  swift build --product RunPlayStudio -Xswiftc -warnings-as-errors \
    || die "swift build failed"
fi
BIN_DIR="$(swift build --show-bin-path)" || die "could not locate the debug build"
APP="$BIN_DIR/RunPlayStudio"
[[ -x "$APP" ]] || die "no debug RunPlayStudio binary at $APP; rerun without --skip-build"

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
  if [[ "$SKIP_GIF" -eq 0 ]]; then
    local mp4 gif
    for mp4 in "$OUTPUT_DIR"/demo-route-replay-*.mp4; do
      gif="${mp4%.mp4}.gif"
      ffmpeg -hide_banner -loglevel error -nostdin -y -i "$mp4" \
        -filter_complex "$GIF_FILTER" -loop 0 -map_metadata -1 "$gif" \
        || die "ffmpeg could not derive $(basename "$gif")"
      log "wrote $(basename "$gif") ($(file_size "$gif") bytes)"
    done
  fi
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
    "$OUTPUT_DIR/$PROVENANCE_FILE"
  )
  if ! check_budget "curated set (summary PNGs, route GIFs, provenance)" ${curated[@]+"${curated[@]}"}; then
    log "warning: this output does not fit the docs/assets budget; do not commit it as is"
    annotate warning "Demo assets over budget" \
      "The curated set does not fit the docs/assets budget; see docs/demo-assets.md."
  fi
}

check() {
  render summary || die "rendering failed"
  local committed_macos current_macos
  committed_macos="$(provenance_value macos "$ASSETS_DIR/$PROVENANCE_FILE")"
  current_macos="$(provenance_value macos "$OUTPUT_DIR/$PROVENANCE_FILE")"
  log "committed cards were rendered on macOS ${committed_macos:-unknown}; this run is on macOS $current_macos"

  local failed=0 reference candidate name status
  local references=("$ASSETS_DIR"/demo-summary-*.png)
  if [[ ${#references[@]} -eq 0 ]]; then
    log "docs/assets has no demo-summary-*.png reference to compare with"
    failed=1
  fi
  for candidate in "$OUTPUT_DIR"/demo-summary-*.png; do
    name="$(basename "$candidate")"
    if [[ ! -f "$ASSETS_DIR/$name" ]]; then
      log "the renderer produced $name, but docs/assets/$name is not committed"
      failed=1
    fi
  done
  for reference in ${references[@]+"${references[@]}"}; do
    name="$(basename "$reference")"
    candidate="$OUTPUT_DIR/$name"
    if [[ ! -f "$candidate" ]]; then
      log "docs/assets/$name is committed, but the renderer no longer produces it"
      failed=1
      continue
    fi
    status=0
    "$APP" --demo-assets compare \
      --reference "$reference" \
      --candidate "$candidate" \
      --diff-output "$OUTPUT_DIR/${name%.png}.diff.png" || status=$?
    case "$status" in
      0) ;;
      1) failed=1 ;;
      *) die "comparing $name failed (exit $status)" ;;
    esac
  done

  local committed=()
  local file
  for file in "$ASSETS_DIR"/*; do
    [[ -f "$file" ]] && committed+=("$file")
  done
  check_budget "docs/assets" ${committed[@]+"${committed[@]}"} || failed=1

  if [[ "$failed" -ne 0 ]]; then
    log "README demo assets are out of date with the renderer or over budget."
    if [[ "$committed_macos" != "$current_macos" ]]; then
      log "The macOS builds differ, and text rasterization can change between builds:"
      log "if the diff images show no real change, refresh docs/assets from this run's cards."
    fi
    log "Rendered cards and magenta diff images are in $OUTPUT_DIR."
    log "If the change is intended, refresh docs/assets as docs/demo-assets.md describes."
    annotate error "README demo assets out of date" \
      "docs/assets no longer matches the renderer or exceeds its budget; the rendered cards and diff images are in the demo-asset-drift artifact. See docs/demo-assets.md."
    exit 1
  fi
  log "README demo summary cards match the renderer"
}

if [[ "$MODE" == "check" ]]; then
  check
else
  generate
fi
