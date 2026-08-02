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

assert_fail_contains() {
  local name="$1"
  local expected="$2"
  shift 2
  local output="$TMP_ROOT/assert-fail-contains.$PASS.$FAIL.log"
  set +e
  "$@" >"$output" 2>&1
  local st=$?
  set -e
  if [[ $st -ne 0 ]] && grep -F -q -- "$expected" "$output"; then
    printf 'PASS: %s (failed with expected diagnostic)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (status=%s; expected diagnostic: %s)\n' "$name" "$st" "$expected" >&2
    cat "$output" >&2 || true
    FAIL=$((FAIL + 1))
  fi
}

release_log "Release packaging tests (tmp=$TMP_ROOT)"

if grep -F -q 'scripts/assemble-app-bundle.sh' "$REPO_ROOT/script/build_and_run.sh" && \
    ! grep -F -q '<plist' "$REPO_ROOT/script/build_and_run.sh"; then
  printf 'PASS: development launcher reuses shared bundle assembler\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: development launcher duplicated bundle assembly\n' >&2
  FAIL=$((FAIL + 1))
fi

# The release workflow writes packaging output inside the checkout. Those
# directories must be git-ignored so artifacts cannot be committed by accident
# and cannot dirty the worktree that production packaging requires to be clean.
WORKFLOW_OUTPUT_DIRS="$(grep -Eo '\$\{GITHUB_WORKSPACE\}/[A-Za-z0-9._-]+' \
  "$REPO_ROOT/.github/workflows/release.yml" | sed -E 's|.*/||' | LC_ALL=C sort -u)"
if [[ -z "$WORKFLOW_OUTPUT_DIRS" ]]; then
  printf 'FAIL: no in-checkout release workflow output directory found to check\n' >&2
  FAIL=$((FAIL + 1))
else
  UNIGNORED_OUTPUT_DIRS=0
  while IFS= read -r workflow_dir; do
    [[ -n "$workflow_dir" ]] || continue
    if ! git -C "$REPO_ROOT" check-ignore -q "$workflow_dir/"; then
      printf 'FAIL: release workflow output directory %s/ is not git-ignored\n' "$workflow_dir" >&2
      UNIGNORED_OUTPUT_DIRS=$((UNIGNORED_OUTPUT_DIRS + 1))
    fi
  done <<<"$WORKFLOW_OUTPUT_DIRS"
  if [[ "$UNIGNORED_OUTPUT_DIRS" -eq 0 ]]; then
    printf 'PASS: release workflow output directories are git-ignored\n'
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + UNIGNORED_OUTPUT_DIRS))
  fi
fi

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

TAG_REPO="$TMP_ROOT/tag-repo"
mkdir -p "$TAG_REPO"
git -C "$TAG_REPO" init -q
git -C "$TAG_REPO" config user.name "RunPlay Packaging Test"
git -C "$TAG_REPO" config user.email "packaging-test@example.invalid"
printf 'first\n' >"$TAG_REPO/payload"
git -C "$TAG_REPO" add payload
git -C "$TAG_REPO" commit -q -m first
git -C "$TAG_REPO" tag v0.1.0
assert_fail "reject lightweight production tag" \
  bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_annotated_tag_at_head '$TAG_REPO' 'v0.1.0'"
git -C "$TAG_REPO" tag -d v0.1.0 >/dev/null
git -C "$TAG_REPO" tag -a v0.1.0 -m "RunPlay Studio 0.1.0"
assert_ok "accept annotated production tag at HEAD" \
  bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_annotated_tag_at_head '$TAG_REPO' 'v0.1.0'"
printf 'second\n' >>"$TAG_REPO/payload"
git -C "$TAG_REPO" add payload
git -C "$TAG_REPO" commit -q -m second
assert_fail "reject annotated tag away from HEAD" \
  bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_annotated_tag_at_head '$TAG_REPO' 'v0.1.0'"

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

DEV_PLIST_OUT="$TMP_ROOT/Info-dev.plist"
bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_generate_info_plist '$REPO_ROOT/Packaging/RunPlayStudio-Info.plist.in' '$DEV_PLIST_OUT' '0.1.0' '1' 'com.shenghaoc.RunPlayStudio'"
DEV_BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEV_PLIST_OUT")"
if [[ "$DEV_BID" == "com.shenghaoc.RunPlayStudio" ]]; then
  printf 'PASS: explicit development bundle identifier override\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: development bundle identifier override (got %s)\n' "$DEV_BID" >&2
  FAIL=$((FAIL + 1))
fi
assert_fail "reject malformed bundle identifier" \
  bash -c "source '$SCRIPT_DIR/lib/release-common.sh'; release_validate_bundle_identifier '../bad'"

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

assert_fail_contains "explicit notarization choice required" \
  "choose exactly one of --notarize or --skip-notarization" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --dry-run --output-dir "$TMP_ROOT/out7"

assert_fail_contains "ad-hoc output must be a dry run" \
  "unsigned and ad-hoc packages require --dry-run" \
  "$SCRIPT_DIR/package-release.sh" --signing-mode adhoc --skip-notarization --output-dir "$TMP_ROOT/out8"

assert_fail_contains "non-notarized Developer ID output must be a dry run" \
  "a non-notarized package requires --dry-run" \
  "$SCRIPT_DIR/package-release.sh" \
    --signing-mode developer-id \
    --signing-identity "Developer ID Application: Test" \
    --skip-notarization \
    --output-dir "$TMP_ROOT/out9"

assert_fail_contains "assembler rejects non-product output basename" \
  "--output must end in RunPlayStudio.app" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/not-the-product.app" \
    --skip-build \
    --bin-dir "$TMP_ROOT/empty-bin" \
    --version 0.1.0 \
    --build-number 1

# ---------------------------------------------------------------------------
# Integration: assemble with mock missing inputs
# ---------------------------------------------------------------------------
assert_fail "assemble missing binary fails" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/missing/RunPlayStudio.app" \
    --skip-build \
    --bin-dir "$TMP_ROOT/empty-bin" \
    --version 0.1.0 \
    --build-number 1

mkdir -p "$TMP_ROOT/empty-bin"
assert_fail "assemble empty bin fails" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$TMP_ROOT/missing2/RunPlayStudio.app" \
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
    --output "$TMP_ROOT/nores/RunPlayStudio.app" \
    --skip-build \
    --bin-dir "$FAKE_BIN" \
    --version 0.1.0 \
    --build-number 1

PRESERVED_APP="$TMP_ROOT/preserved/RunPlayStudio.app"
mkdir -p "$PRESERVED_APP"
printf 'known-good\n' >"$PRESERVED_APP/marker"
assert_fail "failed assembly leaves prior complete app untouched" \
  "$SCRIPT_DIR/assemble-app-bundle.sh" \
    --output "$PRESERVED_APP" \
    --skip-build \
    --bin-dir "$FAKE_BIN" \
    --version 0.1.0 \
    --build-number 1
if [[ "$(cat "$PRESERVED_APP/marker")" == "known-good" ]]; then
  printf 'PASS: staged assembly preserves prior app on failure\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: failed assembly replaced prior app\n' >&2
  FAIL=$((FAIL + 1))
fi

PRESERVED_SET="$TMP_ROOT/preserved-release-set"
mkdir -p "$PRESERVED_SET/RunPlayStudio.app"
printf 'old-app\n' >"$PRESERVED_SET/RunPlayStudio.app/marker"
printf 'old-zip\n' >"$PRESERVED_SET/RunPlayStudio-0.1.0-macos-arm64.zip"
printf 'old-manifest\n' >"$PRESERVED_SET/RunPlayStudio-0.1.0-release.json"
printf 'old-sums\n' >"$PRESERVED_SET/SHA256SUMS"
assert_fail "failed package run does not publish staged output" \
  "$SCRIPT_DIR/package-release.sh" \
    --signing-mode adhoc \
    --skip-notarization \
    --dry-run \
    --output-dir "$PRESERVED_SET" \
    --skip-build \
    --bin-dir "$FAKE_BIN"
if [[ "$(cat "$PRESERVED_SET/RunPlayStudio.app/marker")" == "old-app" ]] && \
    [[ "$(cat "$PRESERVED_SET/RunPlayStudio-0.1.0-macos-arm64.zip")" == "old-zip" ]] && \
    [[ "$(cat "$PRESERVED_SET/RunPlayStudio-0.1.0-release.json")" == "old-manifest" ]] && \
    [[ "$(cat "$PRESERVED_SET/SHA256SUMS")" == "old-sums" ]] && \
    ! find "$PRESERVED_SET" -maxdepth 1 -name '.runplay-release-stage.*' | grep -q .; then
  printf 'PASS: staged package failure preserves the prior complete artifact set\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: failed package run changed the prior artifact set or leaked staging output\n' >&2
  FAIL=$((FAIL + 1))
fi

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

  ENTITLED_APP="$TMP_ROOT/entitled/RunPlayStudio.app"
  mkdir -p "$(dirname "$ENTITLED_APP")"
  cp -R "$APP" "$ENTITLED_APP"
  ENTITLEMENTS_PLIST="$TMP_ROOT/unexpected-entitlements.plist"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.get-task-allow bool true' \
    "$ENTITLEMENTS_PLIST" >/dev/null
  codesign --force --sign - --entitlements "$ENTITLEMENTS_PLIST" "$ENTITLED_APP" >/dev/null
  assert_fail_contains "unexpected custom entitlements fail verification" \
    "unexpected custom entitlements" \
    "$SCRIPT_DIR/verify-app-bundle.sh" \
      --app "$ENTITLED_APP" \
      --expected-signing-mode adhoc \
      --expected-version 0.1.0 \
      --expected-build-number 9
fi

if find "$RELEASE_OUT" -maxdepth 1 -name '*.app-contents.txt' | grep -q .; then
  printf 'FAIL: unexpected app-contents sidecar artifact\n' >&2
  FAIL=$((FAIL + 1))
else
  printf 'PASS: no undocumented app-contents sidecar artifact\n'
  PASS=$((PASS + 1))
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
