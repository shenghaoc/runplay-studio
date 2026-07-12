#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/verify.sh <mode>

Modes:
  core          Build and test RunPlayCore with warnings treated as errors.
  platform      Build and test RunPlayPlatform on macOS with warnings as errors.
  full          Build and test the full macOS package with warnings as errors.
USAGE
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' "This verification mode requires macOS." >&2
    exit 1
  fi
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

case "$1" in
  core)
    run swift build --target RunPlayCore -Xswiftc -warnings-as-errors
    run swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors
    ;;
  platform)
    require_macos
    run swift build --target RunPlayPlatform -Xswiftc -warnings-as-errors
    run swift test --filter RunPlayPlatformTests -Xswiftc -warnings-as-errors
    ;;
  full)
    require_macos
    run swift build -Xswiftc -warnings-as-errors
    run swift test -Xswiftc -warnings-as-errors
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
