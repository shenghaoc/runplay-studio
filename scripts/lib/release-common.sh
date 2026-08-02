#!/usr/bin/env bash
# Shared helpers for RunPlay Studio packaging and release tooling.
# Source this file; do not execute it directly.
#
# Safe to source multiple times. Never prints secrets.

if [[ -n "${RUNPLAY_RELEASE_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RUNPLAY_RELEASE_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Product constants (single source of packaging identity)
# ---------------------------------------------------------------------------
RUNPLAY_PRODUCT_NAME="RunPlayStudio"
RUNPLAY_PRODUCT_DISPLAY_NAME="RunPlay Studio"
RUNPLAY_BUNDLE_IDENTIFIER="com.shenghaoc.runplay-studio"
RUNPLAY_MINIMUM_SYSTEM_VERSION="26.0"
RUNPLAY_SUPPORTED_ARCHITECTURE="arm64"
RUNPLAY_EXECUTABLE_NAME="RunPlayStudio"
RUNPLAY_RESOURCE_BUNDLE_NAME="RunPlayStudio_RunPlayStudio.bundle"
RUNPLAY_CPP_STANDARD="C++23"

# Max practical CFBundleVersion digit length (prevents absurd values).
RUNPLAY_MAX_BUILD_NUMBER_DIGITS=9

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
release_log() {
  printf '==> %s\n' "$*"
}

release_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

release_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Version / build-number validation
# ---------------------------------------------------------------------------

# Read VERSION file (first non-empty line). Allow one trailing newline only
# in the file content after trim of the single line.
release_read_version_file() {
  local version_file="${1:-}"
  [[ -n "$version_file" ]] || release_die "release_read_version_file: path required"
  [[ -f "$version_file" ]] || release_die "VERSION file not found: $version_file"

  local raw
  raw="$(tr -d '\r' <"$version_file")"
  # Reject if more than one trailing newline or interior newlines after strip.
  local line_count
  line_count="$(printf '%s' "$raw" | wc -l | tr -d ' ')"
  # If file is "0.1.0\n", printf of raw has 0 newlines when we strip trailing...
  # Count actual lines in file:
  line_count="$(wc -l <"$version_file" | tr -d ' ')"
  if [[ "$line_count" -gt 1 ]]; then
    release_die "VERSION file must contain a single line (found $line_count lines): $version_file"
  fi

  local version
  version="$(printf '%s' "$raw" | tr -d '\n')"
  release_validate_version "$version"
  printf '%s' "$version"
}

# Semantic version: exactly three nonnegative integer components, no v prefix,
# no prerelease, no whitespace.
release_validate_version() {
  local version="${1:-}"
  if [[ -z "$version" ]]; then
    release_die "version must not be blank"
  fi
  if [[ "$version" =~ [[:space:]] ]]; then
    release_die "version must not contain whitespace: '$version'"
  fi
  if [[ "$version" == v* ]]; then
    release_die "version must not include a leading 'v' (got '$version'); use x.y.z"
  fi
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    release_die "version must be exactly three nonnegative integer components (x.y.z); got '$version'"
  fi
  # Reject leading-zero multi-digit components? Product allows 0.1.0; reject only negatives (regex already).
  # Explicitly reject empty components already covered by regex.
  return 0
}

# Positive integer build number: digits only, > 0, bounded length.
release_validate_build_number() {
  local build="${1:-}"
  if [[ -z "$build" ]]; then
    release_die "build number must not be blank"
  fi
  if [[ "$build" =~ [[:space:]] ]]; then
    release_die "build number must not contain whitespace: '$build'"
  fi
  if [[ ! "$build" =~ ^[0-9]+$ ]]; then
    release_die "build number must contain digits only: '$build'"
  fi
  if [[ "$build" =~ ^0 ]]; then
    # Allow only if the whole value is not zero — reject 0, 00, 01, etc.
    if [[ "$build" == "0" ]] || [[ "$build" =~ ^0[0-9] ]]; then
      release_die "build number must be a positive integer without leading zeros: '$build'"
    fi
  fi
  # Positive: reject 0 already; any other all-digit string starting without 0 is >= 1.
  if (( 10#$build < 1 )); then
    release_die "build number must be greater than zero: '$build'"
  fi
  if (( ${#build} > RUNPLAY_MAX_BUILD_NUMBER_DIGITS )); then
    release_die "build number exceeds maximum length of $RUNPLAY_MAX_BUILD_NUMBER_DIGITS digits: '$build'"
  fi
  return 0
}

# Tag form: v<VERSION contents>
release_validate_release_tag() {
  local tag="${1:-}"
  local expected_version="${2:-}"
  if [[ -z "$tag" ]]; then
    release_die "release tag must not be blank"
  fi
  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    release_die "release tag must match vX.Y.Z; got '$tag'"
  fi
  local tag_version="${tag#v}"
  release_validate_version "$tag_version"
  if [[ -n "$expected_version" && "$tag_version" != "$expected_version" ]]; then
    release_die "release tag '$tag' does not match VERSION '$expected_version'"
  fi
  return 0
}

release_validate_architecture() {
  local arch="${1:-}"
  if [[ "$arch" != "$RUNPLAY_SUPPORTED_ARCHITECTURE" ]]; then
    release_die "unsupported architecture '$arch' (only $RUNPLAY_SUPPORTED_ARCHITECTURE is supported)"
  fi
}

# ---------------------------------------------------------------------------
# Paths / artifacts
# ---------------------------------------------------------------------------

release_versioned_stem() {
  local version="${1:?}"
  local arch="${2:-$RUNPLAY_SUPPORTED_ARCHITECTURE}"
  printf 'RunPlayStudio-%s-macos-%s' "$version" "$arch"
}

release_artifact_app_name() {
  # Outer directory name for versioned app placement (optional).
  # Internal bundle remains RunPlayStudio.app.
  release_versioned_stem "$@"
}

release_artifact_zip_name() {
  printf '%s.zip' "$(release_versioned_stem "$@")"
}

release_artifact_manifest_name() {
  local version="${1:?}"
  printf 'RunPlayStudio-%s-release.json' "$version"
}

# ---------------------------------------------------------------------------
# Info.plist generation from template
# ---------------------------------------------------------------------------

release_generate_info_plist() {
  local template="${1:?}"
  local output="${2:?}"
  local version="${3:?}"
  local build_number="${4:?}"

  release_validate_version "$version"
  release_validate_build_number "$build_number"
  [[ -f "$template" ]] || release_die "Info.plist template not found: $template"

  # Use sed with a delimiter unlikely in values.
  sed \
    -e "s|@CFBundleDisplayName@|${RUNPLAY_PRODUCT_DISPLAY_NAME}|g" \
    -e "s|@CFBundleExecutable@|${RUNPLAY_EXECUTABLE_NAME}|g" \
    -e "s|@CFBundleIdentifier@|${RUNPLAY_BUNDLE_IDENTIFIER}|g" \
    -e "s|@CFBundleName@|${RUNPLAY_PRODUCT_NAME}|g" \
    -e "s|@CFBundleShortVersionString@|${version}|g" \
    -e "s|@CFBundleVersion@|${build_number}|g" \
    -e "s|@LSMinimumSystemVersion@|${RUNPLAY_MINIMUM_SYSTEM_VERSION}|g" \
    "$template" >"$output"

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$output" >/dev/null || release_die "generated Info.plist failed plutil -lint: $output"
  fi
}

# ---------------------------------------------------------------------------
# SHA-256 helpers (portable macOS)
# ---------------------------------------------------------------------------

release_sha256_file() {
  local path="${1:?}"
  [[ -f "$path" ]] || release_die "file for checksum not found: $path"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    release_die "neither shasum nor sha256sum is available"
  fi
}

# Write SHA256SUMS in standard "hash  filename" form (two spaces).
release_write_sha256sums() {
  local output_file="${1:?}"
  shift
  local path base hash
  : >"$output_file"
  for path in "$@"; do
    [[ -f "$path" ]] || release_die "missing artifact for SHA256SUMS: $path"
    base="$(basename "$path")"
    hash="$(release_sha256_file "$path")"
    printf '%s  %s\n' "$hash" "$base" >>"$output_file"
  done
}

release_validate_sha256sums() {
  local sums_file="${1:?}"
  local dir
  dir="$(cd "$(dirname "$sums_file")" && pwd)"
  [[ -f "$sums_file" ]] || release_die "SHA256SUMS not found: $sums_file"
  (
    cd "$dir"
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -c "$(basename "$sums_file")"
    else
      sha256sum -c "$(basename "$sums_file")"
    fi
  )
}

# ---------------------------------------------------------------------------
# Git metadata (best-effort; never fails hard for dirty when not required)
# ---------------------------------------------------------------------------

release_git_commit_sha() {
  local repo_root="${1:-.}"
  if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo_root" rev-parse HEAD
  else
    printf 'unknown'
  fi
}

release_require_clean_worktree() {
  local repo_root="${1:-.}"
  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]]; then
    release_die "working tree is dirty; commit or stash changes before production release packaging"
  fi
}

# ---------------------------------------------------------------------------
# JSON string escape (minimal)
# ---------------------------------------------------------------------------

release_json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Toolchain versions (best-effort)
# ---------------------------------------------------------------------------

release_swift_version() {
  if command -v swift >/dev/null 2>&1; then
    swift --version 2>/dev/null | head -n 1 | sed -E 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' || printf 'unknown'
  else
    printf 'unknown'
  fi
}

release_xcode_version() {
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version 2>/dev/null | head -n 1 | awk '{print $2}' || printf 'unknown'
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Find Mach-O code objects under a bundle (not ordinary resources).
# Prints absolute paths, one per line.
# ---------------------------------------------------------------------------

release_find_macho_code_objects() {
  # Bash 3.2 compatible (macOS /bin/bash). No associative arrays.
  local app_path="${1:?}"
  [[ -d "$app_path" ]] || release_die "app bundle not found: $app_path"

  local tmp_list
  tmp_list="$(mktemp "${TMPDIR:-/tmp}/runplay-macho.XXXXXX")"
  # Structured locations plus any executable-bit files under Contents.
  {
    find "$app_path/Contents" \( \
      -path '*/MacOS/*' -o \
      -path '*/Frameworks/*' -o \
      -path '*/PlugIns/*' -o \
      -path '*/XPCServices/*' -o \
      -path '*/Helpers/*' -o \
      -path '*/Library/*' \
      \) -type f 2>/dev/null || true
    find "$app_path/Contents" -type f -perm -111 2>/dev/null || true
  } | LC_ALL=C sort -u >"$tmp_list"

  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if file -b "$path" 2>/dev/null | grep -q 'Mach-O'; then
      printf '%s\n' "$path"
    fi
  done <"$tmp_list"
  rm -f "$tmp_list"
}

# Sign code objects inside-out: nested first, then outer bundle.
# identity: "-" for ad-hoc, or a Developer ID Application identity string.
release_codesign_bundle() {
  local app_path="${1:?}"
  local identity="${2:?}"
  local mode="${3:?}" # adhoc | developer-id

  local -a nested=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    # Skip the main executable; it is signed with the outer bundle.
    if [[ "$path" == "$app_path/Contents/MacOS/$RUNPLAY_EXECUTABLE_NAME" ]]; then
      continue
    fi
    nested+=("$path")
  done < <(release_find_macho_code_objects "$app_path")

  local obj
  for obj in "${nested[@]+"${nested[@]}"}"; do
    release_log "Signing nested code: $obj"
    if [[ "$mode" == "developer-id" ]]; then
      codesign --force --options runtime --timestamp --sign "$identity" "$obj"
    else
      codesign --force --sign "$identity" "$obj"
    fi
  done

  release_log "Signing outer bundle: $app_path"
  if [[ "$mode" == "developer-id" ]]; then
    codesign --force --options runtime --timestamp --sign "$identity" "$app_path"
  else
    codesign --force --sign "$identity" "$app_path"
  fi
}

# ---------------------------------------------------------------------------
# Dependency summary for manifest (ZIPFoundation vendored)
# ---------------------------------------------------------------------------

release_dependency_summary() {
  printf 'ZIPFoundation 0.9.20 (vendored MIT, ThirdParty/ZIPFoundation)'
}
