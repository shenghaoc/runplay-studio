#!/usr/bin/env bash
# assemble-app-bundle.sh — Deterministic macOS .app assembly from a SwiftPM
# release build. Does not sign, zip, notarize, or publish.
#
# Usage:
#   ./scripts/assemble-app-bundle.sh \
#     --output <path/to/RunPlayStudio.app> \
#     [--repo-root <path>] \
#     [--version <x.y.z>] \
#     [--build-number <positive-int>] \
#     [--bin-dir <swiftpm-bin-path>] \
#     [--skip-build]
#
# When --bin-dir is omitted, performs `swift build -c release` and uses
# `swift build -c release --show-bin-path`.
#
# Environment:
#   RUNPLAY_ASSEMBLE_SKIP_BUILD=1  equivalent to --skip-build (requires --bin-dir)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_APP=""
VERSION=""
BUILD_NUMBER="1"
BIN_DIR=""
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Usage: assemble-app-bundle.sh --output <RunPlayStudio.app> [options]

Assemble a macOS application bundle from a SwiftPM release build.

Options:
  --output <path>          Destination .app path (required)
  --repo-root <path>       Repository root (default: parent of scripts/)
  --version <x.y.z>        Marketing version (default: contents of VERSION)
  --build-number <int>     CFBundleVersion positive integer (default: 1)
  --bin-dir <path>         Existing SwiftPM release bin directory
  --skip-build             Do not run swift build (requires --bin-dir)
  -h, --help               Show this help

This script never signs, zips, notarizes, or publishes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_APP="${2:-}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="$(cd "${2:-}" && pwd)"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="${2:-}"
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
      release_die "unknown option: $1 (use --help)"
      ;;
  esac
done

if [[ -z "$OUTPUT_APP" ]]; then
  release_die "--output is required"
fi

if [[ "${RUNPLAY_ASSEMBLE_SKIP_BUILD:-}" == "1" ]]; then
  SKIP_BUILD=1
fi

VERSION_FILE="$REPO_ROOT/VERSION"
TEMPLATE="$REPO_ROOT/Packaging/RunPlayStudio-Info.plist.in"

if [[ -z "$VERSION" ]]; then
  VERSION="$(release_read_version_file "$VERSION_FILE")"
else
  release_validate_version "$VERSION"
fi
release_validate_build_number "$BUILD_NUMBER"

[[ -f "$TEMPLATE" ]] || release_die "missing Info.plist template: $TEMPLATE"

# Resolve output path (may not exist yet).
OUTPUT_PARENT="$(dirname "$OUTPUT_APP")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd)"
OUTPUT_APP="$OUTPUT_PARENT/$(basename "$OUTPUT_APP")"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
  [[ -n "$BIN_DIR" ]] || release_die "--skip-build requires --bin-dir"
else
  release_log "Building release binary (warnings-as-errors)..."
  swift build -c release --package-path "$REPO_ROOT" -Xswiftc -warnings-as-errors
  if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"
  fi
fi

BIN_DIR="$(cd "$BIN_DIR" && pwd)"
BINARY="$BIN_DIR/$RUNPLAY_EXECUTABLE_NAME"
RESOURCE_BUNDLE="$BIN_DIR/$RUNPLAY_RESOURCE_BUNDLE_NAME"

if [[ ! -f "$BINARY" ]]; then
  release_die "release binary not found at $BINARY"
fi
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  release_die "SwiftPM resource bundle not found at $RESOURCE_BUNDLE (demo resources required)"
fi

# Detect duplicate unexpected executables at bin root (sanity).
if [[ -f "$BIN_DIR/${RUNPLAY_EXECUTABLE_NAME}.debug.dylib" ]]; then
  release_warn "debug dylib present next to release binary; not packaging it"
fi

release_log "Assembling app bundle at $OUTPUT_APP"
rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"

# Install executable with permissions preserved.
cp "$BINARY" "$OUTPUT_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME"
chmod +x "$OUTPUT_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME"

# Install SwiftPM resource bundle where Bundle.module expects it.
cp -R "$RESOURCE_BUNDLE" "$OUTPUT_APP/Contents/Resources/"

# Generate Info.plist from template.
release_generate_info_plist \
  "$TEMPLATE" \
  "$OUTPUT_APP/Contents/Info.plist" \
  "$VERSION" \
  "$BUILD_NUMBER"

# Reject empty MacOS directory outcomes.
if [[ ! -x "$OUTPUT_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME" ]]; then
  release_die "executable missing or not executable after assembly"
fi

release_log "Assembled unsigned app bundle: $OUTPUT_APP"
release_log "  version=$VERSION build=$BUILD_NUMBER id=$RUNPLAY_BUNDLE_IDENTIFIER"
printf '%s\n' "$OUTPUT_APP"
