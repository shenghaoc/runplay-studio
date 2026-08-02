#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RunPlayStudio"
BUNDLE_ID="com.shenghaoc.RunPlayStudio"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BIN_DIR="$(swift build --show-bin-path)"
"$ROOT_DIR/scripts/assemble-app-bundle.sh" \
  --repo-root "$ROOT_DIR" \
  --output "$APP_BUNDLE" \
  --bundle-identifier "$BUNDLE_ID" \
  --skip-build \
  --bin-dir "$BUILD_BIN_DIR"

open_app() {
  if [[ -n "${RUNPLAY_STUDIO_TEST_HOME:-}" ]]; then
    if [[ "$RUNPLAY_STUDIO_TEST_HOME" != /* || "$RUNPLAY_STUDIO_TEST_HOME" == "/" ]]; then
      echo "RUNPLAY_STUDIO_TEST_HOME must be a non-root absolute path" >&2
      exit 2
    fi
    mkdir -p "$RUNPLAY_STUDIO_TEST_HOME"
    /usr/bin/open -n -F --env "CFFIXED_USER_HOME=$RUNPLAY_STUDIO_TEST_HOME" "$APP_BUNDLE"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
