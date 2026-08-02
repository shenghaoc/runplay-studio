#!/usr/bin/env bash
# package-release.sh — Versioned macOS release packaging for RunPlay Studio.
#
# Supports unsigned structural diagnostics, ad-hoc dry runs, and Developer ID
# signing with optional notarization when credentials are supplied.
#
# Never creates a Git tag or GitHub Release. Never prints secret values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR=""
VERSION=""
BUILD_NUMBER=""
ARCHITECTURE="$RUNPLAY_SUPPORTED_ARCHITECTURE"
SIGNING_MODE=""
SIGNING_IDENTITY=""
NOTARIZE=0
SKIP_NOTARIZATION=0
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
DRY_RUN_FLAG=0
SKIP_BUILD=0
BIN_DIR=""
REQUIRE_CLEAN=0
GIT_TAG=""

# Cleanup state
CLEANUP_DIRS=()
TEMP_NOTARY_ZIP=""

usage() {
  cat <<'EOF'
Usage: package-release.sh --signing-mode <mode> [options]

Build a versioned RunPlay Studio release artifact set.

Required:
  --signing-mode unsigned|adhoc|developer-id

Options:
  --output-dir <path>           Output directory (default: .build/release-artifacts)
  --version <x.y.z>             Marketing version (default: VERSION file)
  --build-number <int>          CFBundleVersion (default: 1, or GITHUB_RUN_NUMBER)
  --architecture arm64          Architecture (only arm64 supported)
  --signing-identity <id>       Developer ID Application identity (developer-id mode)
  --notarize                    Notarize after Developer ID signing
  --skip-notarization           Explicitly skip; non-production dry runs only
  --notary-key <path>           App Store Connect API key .p8 path
  --notary-key-id <id>          API key ID
  --notary-issuer <uuid>        API issuer UUID
  --dry-run                     Required for unsigned, ad-hoc, or non-notarized output
  --skip-build                  Reuse --bin-dir without building
  --bin-dir <path>              Existing SwiftPM release bin directory
  --require-clean-worktree      Fail if git worktree is dirty; required for production
  --git-tag <tag>               Annotated production tag at HEAD; required for production
  -h, --help                    Show this help

Artifact naming (outer):
  RunPlayStudio.app                          (working bundle)
  RunPlayStudio-<version>-macos-arm64.zip
  RunPlayStudio-<version>-release.json
  SHA256SUMS

Examples:
  # Ad-hoc dry run (no Apple credentials)
  ./scripts/package-release.sh --signing-mode adhoc --skip-notarization \
      --output-dir /private/tmp/runplay-v0.1-dry-run --dry-run

  # Developer ID + notarization (credentials required)
  ./scripts/package-release.sh --signing-mode developer-id \
      --signing-identity "Developer ID Application: …" \
      --notarize \
      --notary-key "$HOME/AuthKey.p8" \
      --notary-key-id "$KEY_ID" \
      --notary-issuer "$ISSUER_ID" \
      --git-tag "v$(tr -d '\n' < VERSION)" \
      --require-clean-worktree
EOF
}

cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
  done
  if [[ -n "$TEMP_NOTARY_ZIP" && -f "$TEMP_NOTARY_ZIP" ]]; then
    rm -f "$TEMP_NOTARY_ZIP" || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --architecture) ARCHITECTURE="${2:-}"; shift 2 ;;
    --signing-mode) SIGNING_MODE="${2:-}"; shift 2 ;;
    --signing-identity) SIGNING_IDENTITY="${2:-}"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --skip-notarization) SKIP_NOTARIZATION=1; shift ;;
    --notary-key) NOTARY_KEY="${2:-}"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="${2:-}"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN_FLAG=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --bin-dir) BIN_DIR="${2:-}"; shift 2 ;;
    --require-clean-worktree) REQUIRE_CLEAN=1; shift ;;
    --git-tag) GIT_TAG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) release_die "unknown option: $1 (use --help)" ;;
  esac
done

# --- argument validation ---
[[ -n "$SIGNING_MODE" ]] || release_die "--signing-mode is required (use --help)"
case "$SIGNING_MODE" in
  unsigned|adhoc|developer-id) ;;
  *) release_die "invalid --signing-mode: $SIGNING_MODE" ;;
esac

release_validate_architecture "$ARCHITECTURE"

if [[ -z "$VERSION" ]]; then
  VERSION="$(release_read_version_file "$REPO_ROOT/VERSION")"
else
  release_validate_version "$VERSION"
  FILE_VERSION="$(release_read_version_file "$REPO_ROOT/VERSION")"
  if [[ "$VERSION" != "$FILE_VERSION" ]]; then
    release_die "--version '$VERSION' does not match VERSION file '$FILE_VERSION'"
  fi
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    BUILD_NUMBER="$GITHUB_RUN_NUMBER"
  else
    BUILD_NUMBER="1"
  fi
fi
release_validate_build_number "$BUILD_NUMBER"

if [[ "$NOTARIZE" -eq 1 && "$SKIP_NOTARIZATION" -eq 1 ]]; then
  release_die "cannot combine --notarize and --skip-notarization"
fi
if [[ "$NOTARIZE" -eq 0 && "$SKIP_NOTARIZATION" -eq 0 ]]; then
  release_die "choose exactly one of --notarize or --skip-notarization"
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  if [[ "$SIGNING_MODE" != "developer-id" ]]; then
    release_die "--notarize requires --signing-mode developer-id (got $SIGNING_MODE)"
  fi
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    release_die "developer-id mode requires --signing-identity"
  fi
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    release_die "developer-id mode must not use ad-hoc identity '-'"
  fi
  # Soft check: identity string should mention Developer ID Application
  if [[ "$SIGNING_IDENTITY" != *"Developer ID Application"* ]]; then
    release_warn "signing identity does not contain 'Developer ID Application'; continuing with provided value"
  fi
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  [[ -n "$NOTARY_KEY" ]] || release_die "--notarize requires --notary-key"
  [[ -n "$NOTARY_KEY_ID" ]] || release_die "--notarize requires --notary-key-id"
  [[ -n "$NOTARY_ISSUER" ]] || release_die "--notarize requires --notary-issuer"
  [[ -f "$NOTARY_KEY" ]] || release_die "notary key file not found: $NOTARY_KEY"
fi

if [[ -n "$GIT_TAG" ]]; then
  release_validate_release_tag "$GIT_TAG" "$VERSION"
  release_validate_annotated_tag_at_head "$REPO_ROOT" "$GIT_TAG"
fi

# Anything other than the complete Developer ID + notarization path is a dry
# run by definition. Refuse an official-looking manifest for unsigned, ad-hoc,
# or deliberately non-notarized output.
if [[ "$DRY_RUN_FLAG" -eq 0 ]]; then
  [[ "$SIGNING_MODE" == "developer-id" ]] || \
    release_die "unsigned and ad-hoc packages require --dry-run"
  [[ "$NOTARIZE" -eq 1 ]] || \
    release_die "a non-notarized package requires --dry-run"
  [[ -n "$GIT_TAG" ]] || \
    release_die "production packaging requires --git-tag"
  [[ "$REQUIRE_CLEAN" -eq 1 ]] || \
    release_die "production packaging requires --require-clean-worktree"
fi

if [[ "$REQUIRE_CLEAN" -eq 1 ]]; then
  release_require_clean_worktree "$REPO_ROOT"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$REPO_ROOT/.build/release-artifacts"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

ZIP_NAME="$(release_artifact_zip_name "$VERSION" "$ARCHITECTURE")"
MANIFEST_NAME="$(release_artifact_manifest_name "$VERSION")"
STAGE_DIR="$(mktemp -d "$OUTPUT_DIR/.runplay-release-stage.XXXXXX")"
CLEANUP_DIRS+=("$STAGE_DIR")
WORK_APP="$STAGE_DIR/$RUNPLAY_PRODUCT_NAME.app"
ZIP_PATH="$STAGE_DIR/$ZIP_NAME"
MANIFEST_PATH="$STAGE_DIR/$MANIFEST_NAME"
SHA256SUMS_PATH="$STAGE_DIR/SHA256SUMS"
FINAL_APP="$OUTPUT_DIR/$RUNPLAY_PRODUCT_NAME.app"
FINAL_ZIP="$OUTPUT_DIR/$ZIP_NAME"
FINAL_MANIFEST="$OUTPUT_DIR/$MANIFEST_NAME"
FINAL_SHA256SUMS="$OUTPUT_DIR/SHA256SUMS"

# Status fields filled during packaging
SIGNING_LABEL=""
HARDENED_RUNTIME="false"
TEAM_IDENTIFIER=""
NOTARIZATION_STATUS="not_requested"
STAPLING_STATUS="not_requested"
GATEKEEPER_STATUS="not_assessed"
SIGNING_IDENTITY_SUMMARY=""

case "$SIGNING_MODE" in
  unsigned)
    SIGNING_LABEL="Unsigned — demo/testing only"
    SIGNING_IDENTITY_SUMMARY="none"
    ;;
  adhoc)
    SIGNING_LABEL="Ad hoc signed — not trusted for public distribution"
    SIGNING_IDENTITY_SUMMARY="adhoc (-)"
    ;;
  developer-id)
    SIGNING_LABEL="Developer ID Application"
    # Summarize without dumping full certificate details
    SIGNING_IDENTITY_SUMMARY="Developer ID Application (identity supplied)"
    ;;
esac

release_log "Release packaging"
release_log "  version=$VERSION build=$BUILD_NUMBER arch=$ARCHITECTURE"
release_log "  signing-mode=$SIGNING_MODE dry-run=$DRY_RUN_FLAG notarize=$NOTARIZE"
release_log "  output=$OUTPUT_DIR"

# 1. Assemble
ASSEMBLE_ARGS=(
  --repo-root "$REPO_ROOT"
  --output "$WORK_APP"
  --version "$VERSION"
  --build-number "$BUILD_NUMBER"
)
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  [[ -n "$BIN_DIR" ]] || release_die "--skip-build requires --bin-dir"
  ASSEMBLE_ARGS+=(--skip-build --bin-dir "$BIN_DIR")
elif [[ -n "$BIN_DIR" ]]; then
  ASSEMBLE_ARGS+=(--bin-dir "$BIN_DIR")
fi

"$SCRIPT_DIR/assemble-app-bundle.sh" "${ASSEMBLE_ARGS[@]}"

# 2. Sign
case "$SIGNING_MODE" in
  unsigned)
    release_log "Leaving bundle unsigned ($SIGNING_LABEL)"
    ;;
  adhoc)
    release_log "Ad-hoc signing ($SIGNING_LABEL)"
    release_codesign_bundle "$WORK_APP" "-" "adhoc"
    codesign --verify --strict --verbose=2 "$WORK_APP"
    codesign --verify --deep --strict --verbose=2 "$WORK_APP"
    ;;
  developer-id)
    release_log "Developer ID signing with hardened runtime + timestamp"
    release_codesign_bundle "$WORK_APP" "$SIGNING_IDENTITY" "developer-id"
    codesign --verify --strict --verbose=2 "$WORK_APP"
    codesign --verify --deep --strict --verbose=2 "$WORK_APP"
    CS_OUT="$(codesign -dvvv "$WORK_APP" 2>&1 || true)"
    if ! printf '%s\n' "$CS_OUT" | grep -q 'Developer ID Application'; then
      release_die "post-sign verification: Developer ID Application authority missing"
    fi
    if printf '%s\n' "$CS_OUT" | grep -Eqi 'flags=.*runtime|Runtime Version'; then
      HARDENED_RUNTIME="true"
    else
      release_die "post-sign verification: hardened runtime not indicated"
    fi
    TEAM_IDENTIFIER="$(printf '%s\n' "$CS_OUT" | awk -F= '/TeamIdentifier=/{print $2; exit}' || true)"
    ;;
esac

# 3. Notarize (developer-id only)
if [[ "$NOTARIZE" -eq 1 ]]; then
  release_log "Creating temporary notarization zip (not the final artifact)"
  TEMP_NOTARY_ZIP="$STAGE_DIR/notarize-submit.zip"
  ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$TEMP_NOTARY_ZIP"

  release_log "Submitting to Apple notary service via notarytool (waiting)..."
  # Never enable xtrace around credential args.
  set +x
  if ! xcrun notarytool submit "$TEMP_NOTARY_ZIP" \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" \
      --wait; then
    NOTARIZATION_STATUS="failed"
    release_warn "retrieve the detailed reason with: xcrun notarytool log <submission-id> --key <key> --key-id <key-id> --issuer <issuer>"
    release_warn "the submission id is printed in the notarytool output above"
    release_die "notarization failed; not publishing release artifacts as official"
  fi
  NOTARIZATION_STATUS="accepted"
  release_log "Notarization accepted; stapling ticket..."
  xcrun stapler staple "$WORK_APP"
  xcrun stapler validate "$WORK_APP"
  STAPLING_STATUS="stapled"
  release_log "Assessing with Gatekeeper..."
  if spctl --assess --type execute --verbose=4 "$WORK_APP"; then
    GATEKEEPER_STATUS="accepted"
  else
    GATEKEEPER_STATUS="rejected"
    release_die "Gatekeeper assessment failed after notarization"
  fi
  rm -f "$TEMP_NOTARY_ZIP"
  TEMP_NOTARY_ZIP=""
elif [[ "$SIGNING_MODE" == "developer-id" ]]; then
  NOTARIZATION_STATUS="skipped"
  STAPLING_STATUS="skipped"
  GATEKEEPER_STATUS="not_assessed"
elif [[ "$SIGNING_MODE" == "adhoc" ]]; then
  NOTARIZATION_STATUS="not_applicable"
  STAPLING_STATUS="not_applicable"
  GATEKEEPER_STATUS="not_expected"
else
  NOTARIZATION_STATUS="not_applicable"
  STAPLING_STATUS="not_applicable"
  GATEKEEPER_STATUS="not_expected"
fi

# 4. Verify the exact app that will be zipped (no rebuild after this point).
VERIFY_MODE="$SIGNING_MODE"
VERIFY_ARGS=(
  --app "$WORK_APP"
  --expected-signing-mode "$VERIFY_MODE"
  --expected-version "$VERSION"
  --expected-build-number "$BUILD_NUMBER"
)
if [[ "$NOTARIZATION_STATUS" == "accepted" ]]; then
  VERIFY_ARGS+=(--expect-notarized --expect-stapled --expect-gatekeeper)
fi
"$SCRIPT_DIR/verify-app-bundle.sh" "${VERIFY_ARGS[@]}"

# Digest of the verified tree immediately before zip — zip must use this tree.
INVENTORY_PRE_ZIP="$STAGE_DIR/inventory-pre-zip.txt"
(
  cd "$WORK_APP"
  find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(release_sha256_file "$f")" "$f"
  done
) >"$INVENTORY_PRE_ZIP"
BUNDLE_DIGEST_AFTER="$(release_sha256_file "$INVENTORY_PRE_ZIP")"

# 5. Final distribution ZIP from the exact verified (and optionally stapled) app
release_log "Creating final distribution zip: $ZIP_NAME"
rm -f "$ZIP_PATH"
(
  cd "$STAGE_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$RUNPLAY_PRODUCT_NAME.app" "$ZIP_PATH"
)

# Confirm the on-disk app was not mutated by zipping.
INVENTORY_POST_ZIP="$STAGE_DIR/inventory-post-zip.txt"
(
  cd "$WORK_APP"
  find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(release_sha256_file "$f")" "$f"
  done
) >"$INVENTORY_POST_ZIP"
if ! cmp -s "$INVENTORY_PRE_ZIP" "$INVENTORY_POST_ZIP"; then
  release_die "app bundle content changed during zip creation"
fi

# 6. Checksums (final post-stapling zip + manifest later)
# Write checksums for zip first; update after manifest.
release_write_sha256sums "$SHA256SUMS_PATH" "$ZIP_PATH"

# 7. Release manifest
COMMIT_SHA="$(release_git_commit_sha "$REPO_ROOT")"
SWIFT_VER="$(release_swift_version)"
XCODE_VER="$(release_xcode_version)"
ZIP_SIZE="$(wc -c <"$ZIP_PATH" | tr -d ' ')"
ZIP_SHA="$(release_sha256_file "$ZIP_PATH")"
BUILD_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DEP_SUMMARY="$(release_dependency_summary)"
DRY_RUN_JSON="false"
if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
  DRY_RUN_JSON="true"
fi
TAG_JSON="null"
if [[ -n "$GIT_TAG" ]]; then
  TAG_JSON="\"$(release_json_escape "$GIT_TAG")\""
fi

# Icon status
ICON_STATUS="missing_custom_icon"

cat >"$MANIFEST_PATH" <<EOF
{
  "product_name": "$(release_json_escape "$RUNPLAY_PRODUCT_DISPLAY_NAME")",
  "marketing_version": "$(release_json_escape "$VERSION")",
  "build_number": "$(release_json_escape "$BUILD_NUMBER")",
  "git_commit_sha": "$(release_json_escape "$COMMIT_SHA")",
  "git_tag": $TAG_JSON,
  "bundle_identifier": "$(release_json_escape "$RUNPLAY_BUNDLE_IDENTIFIER")",
  "minimum_macos_version": "$(release_json_escape "$RUNPLAY_MINIMUM_SYSTEM_VERSION")",
  "architecture": "$(release_json_escape "$ARCHITECTURE")",
  "universal_binary": false,
  "xcode_version": "$(release_json_escape "$XCODE_VER")",
  "swift_version": "$(release_json_escape "$SWIFT_VER")",
  "cpp_standard": "$(release_json_escape "$RUNPLAY_CPP_STANDARD")",
  "artifact_filename": "$(release_json_escape "$ZIP_NAME")",
  "artifact_size_bytes": $ZIP_SIZE,
  "artifact_sha256": "$(release_json_escape "$ZIP_SHA")",
  "inner_bundle_name": "$(release_json_escape "$RUNPLAY_PRODUCT_NAME.app")",
  "signing_mode": "$(release_json_escape "$SIGNING_MODE")",
  "signing_label": "$(release_json_escape "$SIGNING_LABEL")",
  "signing_identity_summary": "$(release_json_escape "$SIGNING_IDENTITY_SUMMARY")",
  "team_identifier": "$(release_json_escape "${TEAM_IDENTIFIER:-}")",
  "hardened_runtime": $HARDENED_RUNTIME,
  "notarization_status": "$(release_json_escape "$NOTARIZATION_STATUS")",
  "stapling_status": "$(release_json_escape "$STAPLING_STATUS")",
  "gatekeeper_status": "$(release_json_escape "$GATEKEEPER_STATUS")",
  "icon_status": "$(release_json_escape "$ICON_STATUS")",
  "build_timestamp_utc": "$(release_json_escape "$BUILD_TS")",
  "dependency_summary": "$(release_json_escape "$DEP_SUMMARY")",
  "dry_run": $DRY_RUN_JSON,
  "bundle_content_digest_pre_zip": "$(release_json_escape "$BUNDLE_DIGEST_AFTER")"
}
EOF

# Refresh SHA256SUMS to include manifest
release_write_sha256sums "$SHA256SUMS_PATH" "$ZIP_PATH" "$MANIFEST_PATH"
release_validate_sha256sums "$SHA256SUMS_PATH"

# 8. ZIP extraction smoke (structure + permissions)
EXTRACT_DIR="$STAGE_DIR/extract"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/$RUNPLAY_PRODUCT_NAME.app"
[[ -d "$EXTRACTED_APP" ]] || release_die "extracted zip missing $RUNPLAY_PRODUCT_NAME.app"
[[ -x "$EXTRACTED_APP/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME" ]] || release_die "extracted executable not executable"
if [[ "$SIGNING_MODE" != "unsigned" ]]; then
  codesign --verify --strict "$EXTRACTED_APP" || release_die "signature did not survive zip extraction"
fi
if [[ "$STAPLING_STATUS" == "stapled" ]]; then
  xcrun stapler validate "$EXTRACTED_APP" || release_die "staple did not survive zip extraction"
fi

# Publish the fully verified set only after every gate has passed. SHA256SUMS is
# moved last and therefore acts as the completion marker for the artifact set.
rm -rf "$FINAL_APP"
rm -f "$FINAL_ZIP" "$FINAL_MANIFEST" "$FINAL_SHA256SUMS"
mv "$WORK_APP" "$FINAL_APP"
mv "$ZIP_PATH" "$FINAL_ZIP"
mv "$MANIFEST_PATH" "$FINAL_MANIFEST"
mv "$SHA256SUMS_PATH" "$FINAL_SHA256SUMS"

release_log "Release packaging complete"
release_log "  app:  $FINAL_APP"
release_log "  zip:  $FINAL_ZIP"
release_log "  manifest: $FINAL_MANIFEST"
release_log "  checksums: $FINAL_SHA256SUMS"
release_log "  signing: $SIGNING_LABEL"
release_log "  notarization: $NOTARIZATION_STATUS"
release_log "  dry_run: $DRY_RUN_JSON"
