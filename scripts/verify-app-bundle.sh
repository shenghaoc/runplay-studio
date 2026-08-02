#!/usr/bin/env bash
# verify-app-bundle.sh — Non-mutating inspection of a packaged .app.
#
# Usage:
#   ./scripts/verify-app-bundle.sh \
#     --app <path/to/RunPlayStudio.app> \
#     --expected-signing-mode unsigned|adhoc|developer-id \
#     [--expected-version x.y.z] \
#     [--expected-build-number N] \
#     [--expect-notarized] \
#     [--expect-stapled] \
#     [--expect-gatekeeper] \
#     [--json-report <path>]
#
# Exit 0 on success, non-zero on any failed check. Never mutates the app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"

APP_PATH=""
EXPECTED_SIGNING_MODE=""
EXPECTED_VERSION=""
EXPECTED_BUILD_NUMBER=""
EXPECT_NOTARIZED=0
EXPECT_STAPLED=0
EXPECT_GATEKEEPER=0
JSON_REPORT=""
FAILURES=0

usage() {
  cat <<'EOF'
Usage: verify-app-bundle.sh --app <RunPlayStudio.app> --expected-signing-mode <mode> [options]

Non-mutating verification of a RunPlay Studio app bundle.

Required:
  --app <path>
  --expected-signing-mode unsigned|adhoc|developer-id

Optional:
  --expected-version <x.y.z>
  --expected-build-number <int>
  --expect-notarized
  --expect-stapled
  --expect-gatekeeper
  --json-report <path>   Write machine-readable check results
  -h, --help
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS: %s\n' "$*"
}

info() {
  printf 'INFO: %s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --expected-signing-mode) EXPECTED_SIGNING_MODE="${2:-}"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --expected-build-number) EXPECTED_BUILD_NUMBER="${2:-}"; shift 2 ;;
    --expect-notarized) EXPECT_NOTARIZED=1; shift ;;
    --expect-stapled) EXPECT_STAPLED=1; shift ;;
    --expect-gatekeeper) EXPECT_GATEKEEPER=1; shift ;;
    --json-report) JSON_REPORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) release_die "unknown option: $1" ;;
  esac
done

[[ -n "$APP_PATH" ]] || release_die "--app is required"
[[ -n "$EXPECTED_SIGNING_MODE" ]] || release_die "--expected-signing-mode is required"

case "$EXPECTED_SIGNING_MODE" in
  unsigned|adhoc|developer-id) ;;
  *) release_die "invalid --expected-signing-mode: $EXPECTED_SIGNING_MODE" ;;
esac

if [[ ! -e "$APP_PATH" ]]; then
  release_die "app path does not exist: $APP_PATH"
fi
if [[ ! -d "$APP_PATH" ]]; then
  release_die "app path is not a directory: $APP_PATH"
fi

APP_PATH="$(cd "$APP_PATH" && pwd)"
PLIST="$APP_PATH/Contents/Info.plist"
EXEC="$APP_PATH/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME"
RESOURCES="$APP_PATH/Contents/Resources"
RESOURCE_BUNDLE="$RESOURCES/$RUNPLAY_RESOURCE_BUNDLE_NAME"

# --- structure ---
[[ -d "$APP_PATH/Contents" ]] && pass "Contents directory exists" || fail "Contents directory missing"
[[ -f "$PLIST" ]] && pass "Info.plist exists" || fail "Info.plist missing"
[[ -f "$EXEC" ]] && pass "executable exists" || fail "executable missing"
[[ -x "$EXEC" ]] && pass "executable bit set" || fail "executable bit not set"
[[ -d "$RESOURCE_BUNDLE" ]] && pass "SwiftPM resource bundle present" || fail "SwiftPM resource bundle missing"

# --- plist ---
if [[ -f "$PLIST" ]]; then
  if plutil -lint "$PLIST" >/dev/null 2>&1; then
    pass "Info.plist valid"
  else
    fail "Info.plist failed plutil -lint"
  fi

  read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
  }

  BID="$(read_plist CFBundleIdentifier)"
  BEXEC="$(read_plist CFBundleExecutable)"
  BNAME="$(read_plist CFBundleName)"
  BDISP="$(read_plist CFBundleDisplayName)"
  BVER="$(read_plist CFBundleShortVersionString)"
  BBUILD="$(read_plist CFBundleVersion)"
  BMIN="$(read_plist LSMinimumSystemVersion)"

  [[ "$BID" == "$RUNPLAY_BUNDLE_IDENTIFIER" ]] && pass "bundle identifier $BID" || fail "bundle identifier expected $RUNPLAY_BUNDLE_IDENTIFIER got '$BID'"
  [[ "$BEXEC" == "$RUNPLAY_EXECUTABLE_NAME" ]] && pass "CFBundleExecutable $BEXEC" || fail "CFBundleExecutable expected $RUNPLAY_EXECUTABLE_NAME got '$BEXEC'"
  [[ "$BNAME" == "$RUNPLAY_PRODUCT_NAME" ]] && pass "CFBundleName $BNAME" || fail "CFBundleName expected $RUNPLAY_PRODUCT_NAME got '$BNAME'"
  [[ "$BDISP" == "$RUNPLAY_PRODUCT_DISPLAY_NAME" ]] && pass "CFBundleDisplayName $BDISP" || fail "CFBundleDisplayName expected $RUNPLAY_PRODUCT_DISPLAY_NAME got '$BDISP'"
  [[ "$BMIN" == "$RUNPLAY_MINIMUM_SYSTEM_VERSION" ]] && pass "LSMinimumSystemVersion $BMIN" || fail "LSMinimumSystemVersion expected $RUNPLAY_MINIMUM_SYSTEM_VERSION got '$BMIN'"

  if [[ -n "$EXPECTED_VERSION" ]]; then
    [[ "$BVER" == "$EXPECTED_VERSION" ]] && pass "marketing version $BVER" || fail "marketing version expected $EXPECTED_VERSION got '$BVER'"
  else
    info "marketing version $BVER"
  fi
  if [[ -n "$EXPECTED_BUILD_NUMBER" ]]; then
    [[ "$BBUILD" == "$EXPECTED_BUILD_NUMBER" ]] && pass "build number $BBUILD" || fail "build number expected $EXPECTED_BUILD_NUMBER got '$BBUILD'"
  else
    info "build number $BBUILD"
  fi
fi

# --- architecture ---
if [[ -f "$EXEC" ]]; then
  FILE_OUT="$(file -b "$EXEC" 2>/dev/null || true)"
  LIPO_OUT="$(lipo -info "$EXEC" 2>/dev/null || true)"
  info "file: $FILE_OUT"
  info "lipo: $LIPO_OUT"
  if printf '%s\n' "$LIPO_OUT" | grep -q "arm64" && ! printf '%s\n' "$LIPO_OUT" | grep -qi "x86_64"; then
    if printf '%s\n' "$LIPO_OUT" | grep -qi "Non-fat"; then
      pass "architecture arm64 (single-arch, not universal)"
    elif printf '%s\n' "$LIPO_OUT" | grep -q "arm64"; then
      # architectures in the fat file
      ARCH_LIST="$(lipo -archs "$EXEC" 2>/dev/null || true)"
      if [[ "$ARCH_LIST" == "arm64" ]]; then
        pass "architecture arm64 only"
      else
        fail "unexpected architectures: $ARCH_LIST (must be arm64 only, not universal)"
      fi
    fi
  else
    fail "expected arm64-only binary; got lipo: $LIPO_OUT"
  fi
fi

# --- privacy / hygiene: no local library or secrets in the bundle ---
PRIVACY_HITS=0
while IFS= read -r -d '' hit; do
  # Allow synthetic fixtures under the SwiftPM resource bundle only when they are
  # known demo resource patterns. Flag anything that looks like a user library.
  rel="${hit#"$APP_PATH/"}"
  case "$rel" in
    Contents/Resources/"$RUNPLAY_RESOURCE_BUNDLE_NAME"/*)
      # Approved synthetic demo resources may include .gpx/.json samples.
      case "$rel" in
        *.p12|*.p8|*.mobileprovision|*/session.json|*/manifest.json)
          fail "disallowed sensitive path in resources: $rel"
          PRIVACY_HITS=$((PRIVACY_HITS + 1))
          ;;
      esac
      ;;
    *)
      fail "unexpected path outside resource bundle: $rel"
      PRIVACY_HITS=$((PRIVACY_HITS + 1))
      ;;
  esac
done < <(find "$APP_PATH" \( \
  -name 'session.json' -o \
  -name 'manifest.json' -o \
  -name '*.p12' -o \
  -name '*.p8' -o \
  -name '*.mobileprovision' -o \
  -name '*.keychain' -o \
  -name '*.keychain-db' \
  \) -print0 2>/dev/null)

# Flag user-library-like directory layouts
if find "$APP_PATH" -type d -name 'workouts' 2>/dev/null | grep -q .; then
  fail "bundle contains a 'workouts' directory (local library leakage)"
  PRIVACY_HITS=$((PRIVACY_HITS + 1))
fi

# Absolute home-path leakage in strings (practical scan of executable only)
if [[ -f "$EXEC" ]] && command -v strings >/dev/null 2>&1; then
  if strings "$EXEC" 2>/dev/null | grep -E -q "/Users/[^/]+/(Documents|Desktop|Downloads)/"; then
    fail "executable strings contain absolute user Documents/Desktop/Downloads paths"
    PRIVACY_HITS=$((PRIVACY_HITS + 1))
  else
    pass "no obvious user home document paths in executable strings"
  fi
fi

if [[ "$PRIVACY_HITS" -eq 0 ]]; then
  pass "privacy hygiene checks clean"
fi

# --- nested Mach-O inventory ---
MACHO_COUNT=0
while IFS= read -r mpath; do
  [[ -n "$mpath" ]] || continue
  MACHO_COUNT=$((MACHO_COUNT + 1))
  info "Mach-O: $mpath"
done < <(release_find_macho_code_objects "$APP_PATH")
info "Mach-O code object count: $MACHO_COUNT"
if [[ "$MACHO_COUNT" -lt 1 ]]; then
  fail "expected at least one Mach-O code object (main executable)"
else
  pass "found $MACHO_COUNT Mach-O code object(s)"
fi

# --- signing ---
CODESIGN_DV=""
CODESIGN_AUTH=""
TEAM_ID=""
RUNTIME_FLAGS=""
if codesign -dvvv "$APP_PATH" >/dev/null 2>&1; then
  CODESIGN_DV="$(codesign -dvvv "$APP_PATH" 2>&1 || true)"
  CODESIGN_AUTH="$(printf '%s\n' "$CODESIGN_DV" | awk -F= '/Authority=/{print $2; exit}' || true)"
  TEAM_ID="$(printf '%s\n' "$CODESIGN_DV" | awk -F= '/TeamIdentifier=/{print $2; exit}' || true)"
  RUNTIME_FLAGS="$(printf '%s\n' "$CODESIGN_DV" | awk -F= '/flags=/{print $2; exit}' || true)"
fi

case "$EXPECTED_SIGNING_MODE" in
  unsigned)
    # Apple Silicon toolchains commonly emit a linker ad-hoc signature on the
    # executable. Demo/unsigned mode means: not Developer ID signed, not
    # notarized, and not presented as a public distribution artifact.
    if printf '%s\n' "$CODESIGN_DV" | grep -q 'Developer ID Application'; then
      fail "unsigned mode must not carry Developer ID Application authority"
    else
      pass "no Developer ID Application authority (demo/unsigned path)"
    fi
    if printf '%s\n' "$CODESIGN_DV" | grep -Eqi 'flags=.*runtime'; then
      # Linker ad-hoc should not claim hardened-runtime production signing.
      info "runtime flags observed on demo binary (inspect if unexpected): $RUNTIME_FLAGS"
    fi
    info "label: Unsigned — demo/testing only"
    info "note: a linker ad-hoc signature on arm64 is allowed for demo; not Gatekeeper-approved"
    ;;
  adhoc)
    if codesign --verify --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
      pass "codesign --verify --strict"
    else
      fail "codesign --verify --strict failed"
    fi
    if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
      pass "codesign --verify --deep --strict"
    else
      fail "codesign --verify --deep --strict failed"
    fi
    if printf '%s\n' "$CODESIGN_DV" | grep -q 'Signature=adhoc'; then
      pass "ad-hoc signature present"
    else
      # On some OS versions Authority may show differently
      if printf '%s\n' "$CODESIGN_DV" | grep -qi 'Authority=.*adhoc\|Signature=adhoc\|flags=0x0'; then
        pass "ad-hoc-like signature"
      else
        fail "expected ad-hoc signature; codesign -dvvv did not show Signature=adhoc"
        info "codesign -dvvv excerpt: $(printf '%s' "$CODESIGN_DV" | head -n 20 | tr '\n' ' ')"
      fi
    fi
    info "label: Ad hoc signed — not trusted for public distribution"
    ;;
  developer-id)
    if codesign --verify --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
      pass "codesign --verify --strict"
    else
      fail "codesign --verify --strict failed"
    fi
    if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
      pass "codesign --verify --deep --strict"
    else
      fail "codesign --verify --deep --strict failed"
    fi
    if printf '%s\n' "$CODESIGN_DV" | grep -q 'Developer ID Application'; then
      pass "Developer ID Application authority present"
    else
      fail "missing Developer ID Application authority"
    fi
    if printf '%s\n' "$RUNTIME_FLAGS" | grep -q 'runtime'; then
      pass "hardened runtime flag present ($RUNTIME_FLAGS)"
    else
      # flags=0x10000(runtime) style
      if printf '%s\n' "$CODESIGN_DV" | grep -Eqi 'flags=.*runtime|Runtime Version'; then
        pass "hardened runtime indicated"
      else
        fail "hardened runtime not indicated in codesign output"
      fi
    fi
    if printf '%s\n' "$CODESIGN_DV" | grep -qi 'Timestamp='; then
      pass "secure timestamp present"
    else
      fail "secure timestamp missing"
    fi
    info "TeamIdentifier=${TEAM_ID:-unknown}"
    ;;
esac

# Entitlements dump (informational)
if codesign -d --entitlements :- "$APP_PATH" >/dev/null 2>&1; then
  ENT_XML="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
  if [[ -z "$ENT_XML" ]] || printf '%s' "$ENT_XML" | grep -q '<dict/>'; then
    pass "no custom entitlements (empty or absent)"
  else
    info "entitlements present (audit required):"
    printf '%s\n' "$ENT_XML" | head -n 40
  fi
else
  info "no entitlements blob (expected for no custom entitlements)"
fi

# Stapling / Gatekeeper only when requested
if [[ "$EXPECT_STAPLED" -eq 1 ]]; then
  if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
    pass "stapler validate succeeded"
  else
    fail "stapler validate failed"
  fi
fi

if [[ "$EXPECT_NOTARIZED" -eq 1 ]]; then
  # Notarization is evidenced by staple or spctl assessment in practice.
  if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
    pass "notarization evidenced by valid staple"
  else
    fail "expected notarized (staple validation failed)"
  fi
fi

if [[ "$EXPECT_GATEKEEPER" -eq 1 ]]; then
  if spctl --assess --type execute --verbose=4 "$APP_PATH" >/dev/null 2>&1; then
    pass "Gatekeeper assessment accepted"
  else
    fail "Gatekeeper assessment rejected"
  fi
fi

if [[ -n "$JSON_REPORT" ]]; then
  mkdir -p "$(dirname "$JSON_REPORT")"
  cat >"$JSON_REPORT" <<EOF
{
  "app_path_basename": "$(release_json_escape "$(basename "$APP_PATH")")",
  "expected_signing_mode": "$(release_json_escape "$EXPECTED_SIGNING_MODE")",
  "failures": $FAILURES,
  "macho_count": $MACHO_COUNT,
  "bundle_identifier": "$(release_json_escape "${BID:-}")",
  "marketing_version": "$(release_json_escape "${BVER:-}")",
  "build_number": "$(release_json_escape "${BBUILD:-}")",
  "team_identifier": "$(release_json_escape "${TEAM_ID:-}")"
}
EOF
fi

if [[ "$FAILURES" -gt 0 ]]; then
  printf 'verify-app-bundle: %d failure(s)\n' "$FAILURES" >&2
  exit 1
fi

printf 'verify-app-bundle: all checks passed\n'
exit 0
