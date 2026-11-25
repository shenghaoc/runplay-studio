#!/usr/bin/env bash
# package-demo.sh — Unsigned demonstration macOS .app packaging.
#
# Usage:
#   ./scripts/package-demo.sh [output-dir]
#
# Produces:
#   <output-dir>/RunPlayStudio.app
#   <output-dir>/RunPlayStudio.app.zip
#
# Label: Unsigned — demo/testing only
#
# Never signs, notarizes, or claims Gatekeeper acceptance. The app comes from
# `xcodebuild archive` of RunPlayStudio.xcodeproj with code signing off
# (release_xcode_archive), so it carries only the linker's signature on its
# executable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/.build/artifacts}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

VERSION="$(release_read_version_file "$REPO_ROOT/VERSION")"
BUILD_NUMBER="${RUNPLAY_DEMO_BUILD_NUMBER:-1}"
release_validate_build_number "$BUILD_NUMBER"

APP_BUNDLE="$OUTPUT_DIR/$RUNPLAY_PRODUCT_NAME.app"
ZIP_PATH="$OUTPUT_DIR/$RUNPLAY_PRODUCT_NAME.app.zip"
ZIP_TEMP="$OUTPUT_DIR/.$RUNPLAY_PRODUCT_NAME.app.zip.tmp.$$"

ARCHIVE_STAGE=""
cleanup() {
  rm -f "$ZIP_TEMP"
  if [[ -n "$ARCHIVE_STAGE" && -d "$ARCHIVE_STAGE" ]]; then
    rm -rf "$ARCHIVE_STAGE"
  fi
}
trap cleanup EXIT

release_log "Packaging unsigned demo artifact (version=$VERSION build=$BUILD_NUMBER)"
release_log "Label: Unsigned — demo/testing only"

# A failed rebuild must not leave an older zip looking like the result of the
# current command. The app itself is replaced only after a complete archive.
rm -f "$ZIP_PATH" "$ZIP_TEMP"

ARCHIVE_STAGE="$(mktemp -d "$OUTPUT_DIR/.runplay-demo-archive.XXXXXX")"
ARCHIVE="$ARCHIVE_STAGE/$RUNPLAY_PRODUCT_NAME.xcarchive"
release_xcode_archive "$REPO_ROOT" "$ARCHIVE" "$VERSION" "$BUILD_NUMBER"
ARCHIVED_APP="$(release_archived_app "$ARCHIVE")"
release_validate_built_app "$ARCHIVED_APP" "$VERSION" "$BUILD_NUMBER"
# Replace the app only once the archive is complete and valid, so a failed
# build cannot leave a partial app behind.
STAGED_APP="$ARCHIVE_STAGE/$RUNPLAY_PRODUCT_NAME.app"
ditto "$ARCHIVED_APP" "$STAGED_APP"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
rm -rf "$ARCHIVE_STAGE"

# Verify the exact app before creating the demo archive.
if [[ -x "$SCRIPT_DIR/verify-app-bundle.sh" ]]; then
  "$SCRIPT_DIR/verify-app-bundle.sh" \
    --app "$APP_BUNDLE" \
    --expected-signing-mode unsigned \
    --expected-version "$VERSION" \
    --expected-build-number "$BUILD_NUMBER" || {
      release_warn "demo structural verification reported issues (see above)"
      # Demo path historically shipped unsigned; fail hard on structure/privacy.
      exit 1
    }
fi

release_log "Creating demo zip archive..."
(
  cd "$OUTPUT_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$RUNPLAY_PRODUCT_NAME.app" "$(basename "$ZIP_TEMP")"
)
mv "$ZIP_TEMP" "$ZIP_PATH"

release_log "Demo packaging complete"
release_log "  app: $APP_BUNDLE"
release_log "  zip: $ZIP_PATH"
release_log "  status: Unsigned — demo/testing only (not notarized; not Gatekeeper-approved)"
