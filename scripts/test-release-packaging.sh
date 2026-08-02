#!/usr/bin/env bash
# test-release-packaging.sh — Credential-free tests for release packaging tooling.
#
# Uses temporary directories only. Does not touch the developer's Application Support.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/runplay-release-tests.XXXXXX")"
PASS=0
FAIL=0
SKIP=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

assert_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$name" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s (expected failure)\n' "$name" >&2
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: %s (failed as expected)\n' "$name"
    PASS=$((PASS + 1))
  fi
}

run_capture() {
  # Run command; return exit status; capture stdout+stderr to file $1
  local out="$1"
  shift
  set +e
  "$@" >"$out" 2>&1
  local st=$?
  set -e
  return $st
}

release_log "Release packaging tests (tmp=$TMP_ROOT)"

# ---------------------------------------------------------------------------
# Unit: version validation
# ---------------------------------------------------------------------------
assert_ok "valid version 0.1.0" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '0.1.0'"
assert_ok "valid version 1.2.3" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '1.2.3'"
assert_fail "reject blank version" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version ''"
assert_fail "reject v-prefix" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version 'v0.1.0'"
assert_fail "reject two-component" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '0.1'"
assert_fail "reject prerelease" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '0.1.0-beta'"
assert_fail "reject whitespace" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '0.1.0 '"
assert_fail "reject negative-looking" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_version '-1.0.0'"

# VERSION file read
printf '0.1.0\n' >"$TMP_ROOT/VERSION.ok"
assert_ok "read VERSION file" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; test \"\$(release_read_version_file '$TMP_ROOT/VERSION.ok')\" = '0.1.0'"
printf 'v0.1.0\n' >"$TMP_ROOT/VERSION.bad"
assert_fail "reject VERSION with v prefix" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_read_version_file '$TMP_ROOT/VERSION.bad'"
printf '0.1.0\n1.0.0\n' >"$TMP_ROOT/VERSION.multi"
assert_fail "reject multi-line VERSION" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_read_version_file '$TMP_ROOT/VERSION.multi'"

# ---------------------------------------------------------------------------
# Unit: build number
# ---------------------------------------------------------------------------
assert_ok "valid build 1" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number '1'"
assert_ok "valid build 42" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number '42'"
assert_fail "reject build 0" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number '0'"
assert_fail "reject build leading zero" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number '01'"
assert_fail "reject build with punctuation" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number '1.0'"
assert_fail "reject build SHA-like" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number 'abc123'"
assert_fail "reject empty build" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_build_number ''"

# ---------------------------------------------------------------------------
# Unit: tag/version agreement
# ---------------------------------------------------------------------------
assert_ok "tag matches version" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_release_tag 'v0.1.0' '0.1.0'"
assert_fail "tag mismatch" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_release_tag 'v0.1.1' '0.1.0'"
assert_fail "malformed tag" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_release_tag '0.1.0' '0.1.0'"
assert_fail "tag with beta" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_release_tag 'v0.1.0-beta' '0.1.0'"

# ---------------------------------------------------------------------------
# Unit: architecture + naming
# ---------------------------------------------------------------------------
assert_ok "arch arm64" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_architecture 'arm64'"
assert_fail "arch x86_64" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_architecture 'x86_64'"
assert_fail "arch universal" bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_architecture 'universal'"

STEM="$(bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_versioned_stem '0.1.0' 'arm64'")"
if [[ "$STEM" == "RunPlayStudio-0.1.0-macos-arm64" ]]; then
  printf 'PASS: deterministic artifact stem\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: deterministic artifact stem (got %s)\n' "$STEM" >&2
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Unit: plist generation
# ---------------------------------------------------------------------------
PLIST_OUT="$TMP_ROOT/Info.plist"
bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_generate_info_plist '$REPO_ROOT/Packaging/RunPlayStudio-Info.plist.in' '$PLIST_OUT' '0.1.0' '7'"
assert_ok "plist lints" plutil -lint "$PLIST_OUT"
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_OUT")"
BVER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_OUT")"
BBUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_OUT")"
BDISP="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST_OUT")"
BCAT="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$PLIST_OUT")"
if [[ "$BID" == "com.shenghaoc.runplay-studio" && "$BVER" == "0.1.0" && "$BBUILD" == "7" && "$BDISP" == "RunPlay Studio" ]]; then
  printf 'PASS: plist field values\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: plist field values (id=%s ver=%s build=%s disp=%s)\n' "$BID" "$BVER" "$BBUILD" "$BDISP" >&2
  FAIL=$((FAIL + 1))
fi
if [[ "$BCAT" == "public.app-category.healthcare-fitness" ]]; then
  printf 'PASS: LSApplicationCategoryType healthcare-fitness\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: LSApplicationCategoryType\n' >&2
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# CLI: package-release argument validation (no full build)
# ---------------------------------------------------------------------------
assert_fail "notarize+unsigned rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode unsigned --notarize --output-dir "$TMP_ROOT/out1"

assert_fail "notarize+adhoc rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --notarize --output-dir "$TMP_ROOT/out2"

assert_fail "developer-id without identity rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode developer-id --skip-notarization --output-dir "$TMP_ROOT/out3"

assert_fail "malformed version rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --version 'v0.1.0' --skip-notarization --output-dir "$TMP_ROOT/out4"

assert_fail "unsupported arch rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --architecture x86_64 --skip-notarization --output-dir "$TMP_ROOT/out5"

assert_fail "bad build number rejected" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --build-number '0' --skip-notarization --output-dir "$TMP_ROOT/out6"

# ---------------------------------------------------------------------------
# Integration: assemble with mock missing inputs
# ---------------------------------------------------------------------------
assert_fail "assemble missing binary fails" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/missing.app" \
    --skip-build \
    --bin-dir "$TMP_ROOT/empty-bin" \
    --version 0.1.0 \
    --build-number 1

mkdir -p "$TMP_ROOT/empty-bin"
assert_fail "assemble empty bin fails" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/missing2.app" \
    --skip-build \
    --bin-dir "$TMP_ROOT/empty-bin" \
    --version 0.1.0 \
    --build-number 1

# ---------------------------------------------------------------------------
# Integration: full ad-hoc dry run (uses real swift build once)
# ---------------------------------------------------------------------------
# Reuse a shared release build if RUNPLAY_TEST_BIN_DIR is set; otherwise build.
INTEGRATION_OUT="$TMP_ROOT/integration"
mkdir -p "$INTEGRATION_OUT"

if [[ -n "${RUNPLAY_TEST_BIN_DIR:-}" && -d "${RUNPLAY_TEST_BIN_DIR}" ]]; then
  release_log "Using provided RUNPLAY_TEST_BIN_DIR=$RUNPLAY_TEST_BIN_DIR"
  TEST_BIN="$RUNPLAY_TEST_BIN_DIR"
else
  release_log "Building release binary for integration tests..."
  swift build -c release --package-path "$REPO_ROOT" -Xswiftc -warnings-as-errors
  TEST_BIN="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"
fi
TEST_BIN="$(cd "$TEST_BIN" && pwd)"

# Missing resource bundle simulation
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cp "$TEST_BIN/$RUNPLAY_EXECUTABLE_NAME" "$FAKE_BIN/"
assert_fail "assemble missing resource bundle fails" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/nores.app" \
    --skip-build \
    --bin-dir "$FAKE_BIN" \
    --version 0.1.0 \
    --build-number 1

# Full adhoc package-release
RELEASE_OUT="$INTEGRATION_OUT/release"
mkdir -p "$RELEASE_OUT"
set +e
"$SCRIPT_DIR/package-release.sh" \
  --signing-mode adhoc \
  --skip-notarization \
  --dry-run \
  --output-dir "$RELEASE_OUT" \
  --build-number 9 \
  --skip-build \
  --bin-dir "$TEST_BIN"
PKG_ST=$?
set -e

if [[ $PKG_ST -eq 0 ]]; then
  printf 'PASS: adhoc package-release dry run\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: adhoc package-release dry run (exit %s)\n' "$PKG_ST" >&2
  FAIL=$((FAIL + 1))
fi

ZIP="$RELEASE_OUT/RunPlayStudio-0.1.0-macos-arm64.zip"
MANIFEST="$RELEASE_OUT/RunPlayStudio-0.1.0-release.json"
SUMS="$RELEASE_OUT/SHA256SUMS"
APP="$RELEASE_OUT/RunPlayStudio.app"

if [[ -f "$ZIP" ]]; then
  printf 'PASS: versioned zip exists\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: versioned zip missing\n' >&2
  FAIL=$((FAIL + 1))
fi

if [[ -f "$MANIFEST" ]]; then
  printf 'PASS: release manifest exists\n'
  PASS=$((PASS + 1))
  if grep -q '"dry_run": true' "$MANIFEST" && grep -q '"notarization_status": "not_applicable"' "$MANIFEST"; then
    printf 'PASS: manifest dry-run and notarization status truthful\n'
    PASS=$((PASS + 1))
  else
    printf 'FAIL: manifest status fields incorrect\n' >&2
    cat "$MANIFEST" >&2 || true
    FAIL=$((FAIL + 1))
  fi
  if grep -q '"signing_mode": "adhoc"' "$MANIFEST"; then
    printf 'PASS: manifest signing_mode adhoc\n'
    PASS=$((PASS + 1))
  else
    printf 'FAIL: manifest signing_mode\n' >&2
    FAIL=$((FAIL + 1))
  fi
  # Must not claim notarized
  if grep -q '"notarization_status": "accepted"' "$MANIFEST"; then
    printf 'FAIL: dry-run claimed notarization accepted\n' >&2
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: dry-run does not claim notarization accepted\n'
    PASS=$((PASS + 1))
  fi
else
  printf 'FAIL: release manifest missing\n' >&2
  FAIL=$((FAIL + 1))
fi

if [[ -f "$SUMS" ]]; then
  if (cd "$RELEASE_OUT" && shasum -a 256 -c SHA256SUMS >/dev/null); then
    printf 'PASS: SHA256SUMS validates\n'
    PASS=$((PASS + 1))
  else
    printf 'FAIL: SHA256SUMS validation\n' >&2
    FAIL=$((FAIL + 1))
  fi
else
  printf 'FAIL: SHA256SUMS missing\n' >&2
  FAIL=$((FAIL + 1))
fi

# Unversioned generic name must not be the published zip
if [[ -f "$RELEASE_OUT/RunPlayStudio.app.zip" ]]; then
  printf 'FAIL: generic RunPlayStudio.app.zip should not be release artifact\n' >&2
  FAIL=$((FAIL + 1))
else
  printf 'PASS: no generic unversioned release zip\n'
  PASS=$((PASS + 1))
fi

# Privacy: no session/manifest library files
if [[ -d "$APP" ]]; then
  if find "$APP" \( -name 'session.json' -o -path '*/workouts/*' \) | grep -q .; then
    printf 'FAIL: privacy — session or workouts present in app\n' >&2
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: privacy — no session.json or workouts library\n'
    PASS=$((PASS + 1))
  fi
  set +e
  "$SCRIPT_DIR/verify-app-bundle.sh" \
    --app "$APP" \
    --expected-signing-mode adhoc \
    --expected-version 0.1.0 \
    --expected-build-number 9
  VST=$?
  set -e
  if [[ $VST -eq 0 ]]; then
    printf 'PASS: verify-app-bundle adhoc\n'
    PASS=$((PASS + 1))
  else
    printf 'FAIL: verify-app-bundle adhoc\n' >&2
    FAIL=$((FAIL + 1))
  fi
fi

# Demo packaging path (unsigned) reusing bin
DEMO_OUT="$INTEGRATION_OUT/demo"
mkdir -p "$DEMO_OUT"
# package-demo always builds; use assemble + zip manually style by calling package-demo
# which rebuilds — for speed, assemble unsigned via package-release unsigned
set +e
"$SCRIPT_DIR/package-release.sh" \
  --signing-mode unsigned \
  --skip-notarization \
  --dry-run \
  --output-dir "$DEMO_OUT" \
  --build-number 1 \
  --skip-build \
  --bin-dir "$TEST_BIN"
UNSIGNED_ST=$?
set -e
if [[ $UNSIGNED_ST -eq 0 ]]; then
  printf 'PASS: unsigned package-release structural path\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: unsigned package-release\n' >&2
  FAIL=$((FAIL + 1))
fi

if [[ -d "$DEMO_OUT/RunPlayStudio.app" ]]; then
  set +e
  "$SCRIPT_DIR/verify-app-bundle.sh" \
    --app "$DEMO_OUT/RunPlayStudio.app" \
    --expected-signing-mode unsigned \
    --expected-version 0.1.0 \
    --expected-build-number 1
  UV=$?
  set -e
  if [[ $UV -eq 0 ]]; then
    printf 'PASS: verify unsigned demo-style bundle\n'
    PASS=$((PASS + 1))
  else
    printf 'FAIL: verify unsigned demo-style bundle\n' >&2
    FAIL=$((FAIL + 1))
  fi
fi

# Forced failure cleanup: ensure temp dirs from a bad run do not linger with secrets.
# (package-release trap cleans STAGE_DIR; we only assert the CLI fails cleanly.)
assert_fail "version override mismatch fails" \
  "$SCRIPT_DIR/package-release.sh" \
    --signing-mode adhoc \
    --version 9.9.9 \
    --skip-notarization \
    --output-dir "$TMP_ROOT/mismatch" \
    --skip-build \
    --bin-dir "$TEST_BIN"

# help exits 0
assert_ok "package-release --help" "$SCRIPT_DIR/package-release.sh" --help
assert_ok "assemble-app-bundle --help" "$SCRIPT_DIR/assemble-app-bundle.sh" --help
assert_ok "verify-app-bundle --help" "$SCRIPT_DIR/verify-app-bundle.sh" --help

printf '\n=== test-release-packaging summary: pass=%d fail=%d skip=%d ===\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
