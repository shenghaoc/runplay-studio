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
# Never signs, notarizes, or claims Gatekeeper acceptance.
# Delegates bundle assembly to scripts/assemble-app-bundle.sh.

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

cleanup() {
  rm -f "$ZIP_TEMP"
}
trap cleanup EXIT

release_log "Packaging unsigned demo artifact (version=$VERSION build=$BUILD_NUMBER)"
release_log "Label: Unsigned — demo/testing only"

# A failed rebuild must not leave an older zip looking like the result of the
# current command. The app itself is replaced atomically by the assembler.
rm -f "$ZIP_PATH" "$ZIP_TEMP"

"$SCRIPT_DIR/assemble-app-bundle.sh" \
  --repo-root "$REPO_ROOT" \
  --output "$APP_BUNDLE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER"

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
