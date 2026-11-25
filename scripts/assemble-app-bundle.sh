#!/usr/bin/env bash
# assemble-app-bundle.sh — Staged, repeatable copy of the Xcode-built
# RunPlayStudio.app, with this release's version, build number and bundle
# identifier. Does not sign, zip, notarize, or publish.
#
# The app is built by RunPlayStudio.xcodeproj (`xcodebuild build`, Release,
# code signing off, so the bundle carries only the linker's signature on the
# executable, as a SwiftPM build did). This script stays only until packaging
# moves to `xcodebuild archive`.
#
# Usage:
#   ./scripts/assemble-app-bundle.sh \
#     --output <path/to/RunPlayStudio.app> \
#     [--repo-root <path>] \
#     [--version <x.y.z>] \
#     [--build-number <positive-int>] \
#     [--bundle-identifier <reverse-dns-id>] \
#     [--bin-dir <xcodebuild-products-dir>] \
#     [--skip-build]
#
# When --bin-dir is omitted, builds the RunPlayStudio scheme in Release into
# .build/xcode-package and uses its Build/Products/Release directory.
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
BUNDLE_IDENTIFIER="$RUNPLAY_BUNDLE_IDENTIFIER"
BIN_DIR=""
SKIP_BUILD=0
ASSEMBLY_STAGE=""

cleanup() {
  if [[ -n "$ASSEMBLY_STAGE" && -d "$ASSEMBLY_STAGE" ]]; then
    rm -rf "$ASSEMBLY_STAGE"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: assemble-app-bundle.sh --output <RunPlayStudio.app> [options]

Copy the Xcode-built RunPlayStudio.app and set its version and identity.

Options:
  --output <path>          Destination .app path (required)
  --repo-root <path>       Repository root (default: parent of scripts/)
  --version <x.y.z>        Marketing version (default: contents of VERSION)
  --build-number <int>     CFBundleVersion positive integer (default: 1)
  --bundle-identifier <id> Bundle identifier (default: distribution identity)
  --bin-dir <path>         Existing xcodebuild products directory that holds
                           RunPlayStudio.app (for example
                           <derived-data>/Build/Products/Release)
  --skip-build             Do not run xcodebuild (requires --bin-dir)
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
    --bundle-identifier)
      BUNDLE_IDENTIFIER="${2:-}"
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

if [[ -z "$VERSION" ]]; then
  VERSION="$(release_read_version_file "$VERSION_FILE")"
else
  release_validate_version "$VERSION"
fi
release_validate_build_number "$BUILD_NUMBER"
release_validate_bundle_identifier "$BUNDLE_IDENTIFIER"

# Resolve output path (may not exist yet).
OUTPUT_PARENT="$(dirname "$OUTPUT_APP")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd)"
OUTPUT_APP="$OUTPUT_PARENT/$(basename "$OUTPUT_APP")"
if [[ "$(basename "$OUTPUT_APP")" != "$RUNPLAY_PRODUCT_NAME.app" ]]; then
  release_die "--output must end in $RUNPLAY_PRODUCT_NAME.app (got $OUTPUT_APP)"
fi

if [[ "$SKIP_BUILD" -eq 1 ]]; then
  [[ -n "$BIN_DIR" ]] || release_die "--skip-build requires --bin-dir"
else
  DERIVED_DATA="$REPO_ROOT/.build/xcode-package"
  release_log "Building the release app with xcodebuild (warnings are errors, per the project's xcconfigs)..."
  # CODE_SIGNING_ALLOWED=NO: packaging signs the bundle itself
  # (release_codesign_bundle), and an unsigned demo bundle keeps only the
  # linker's signature on the executable. The project builds arm64 only.
  xcodebuild build \
    -project "$REPO_ROOT/RunPlayStudio.xcodeproj" \
    -scheme "$RUNPLAY_PRODUCT_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    "$RUNPLAY_XCODEBUILD_PACKAGE_WARNINGS" \
    CODE_SIGNING_ALLOWED=NO
  if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$DERIVED_DATA/Build/Products/Release"
  fi
fi

[[ -d "$BIN_DIR" ]] || release_die "xcodebuild products directory not found: $BIN_DIR"
BIN_DIR="$(cd "$BIN_DIR" && pwd)"
BUILT_APP="$BIN_DIR/$RUNPLAY_PRODUCT_NAME.app"
BINARY="$BUILT_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME"
BUILT_RESOURCES="$BUILT_APP/Contents/Resources"

if [[ ! -f "$BINARY" ]]; then
  release_die "release binary not found at $BINARY"
fi
if [[ ! -f "$BUILT_RESOURCES/$RUNPLAY_STUDIO_RESOURCE_SAMPLE" ]]; then
  release_die "Studio resources not found at $BUILT_RESOURCES/$RUNPLAY_STUDIO_RESOURCE_SAMPLE (demo resources required)"
fi
for bundle_name in $RUNPLAY_RESOURCE_BUNDLE_NAMES; do
  if [[ ! -d "$BUILT_RESOURCES/$bundle_name" ]]; then
    release_die "SwiftPM resource bundle not found at $BUILT_RESOURCES/$bundle_name (localized strings required)"
  fi
done
# SwiftUI literals and Studio's own strings resolve against the main bundle,
# where Xcode compiles the Studio catalog.
for language in $RUNPLAY_LOCALIZATIONS; do
  [[ "$language" == "en" ]] && continue
  if [[ ! -f "$BUILT_RESOURCES/$language.lproj/Localizable.strings" ]]; then
    release_die "compiled $language strings missing from $BUILT_APP (String Catalog not compiled?)"
  fi
done

ASSEMBLY_STAGE="$(mktemp -d "$OUTPUT_PARENT/.runplay-assemble.XXXXXX")"
STAGED_APP="$ASSEMBLY_STAGE/$RUNPLAY_PRODUCT_NAME.app"

release_log "Assembling app bundle at $OUTPUT_APP"
ditto "$BUILT_APP" "$STAGED_APP"

# This release's version, build number and identifier. The project's
# Info.plist takes them from build settings; set them here so one build serves
# every packaging run that reuses it.
STAGED_PLIST="$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" \
  "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST" >/dev/null || release_die "Info.plist failed plutil -lint: $STAGED_PLIST"

# Reject empty MacOS directory outcomes.
if [[ ! -x "$STAGED_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME" ]]; then
  release_die "executable missing or not executable after assembly"
fi

# Replace only the validated product bundle after the staged assembly is
# complete, so a failed copy or plist edit cannot leave a partial app.
rm -rf "$OUTPUT_APP"
mv "$STAGED_APP" "$OUTPUT_APP"

release_log "Assembled unsigned app bundle: $OUTPUT_APP"
release_log "  version=$VERSION build=$BUILD_NUMBER id=$BUNDLE_IDENTIFIER"
printf '%s\n' "$OUTPUT_APP"
