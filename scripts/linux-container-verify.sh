#!/usr/bin/env bash
# Single source of the local Linux container-verification invocation —
# the keyed pin read, shape guard, runtime flags, and HOME/scratch
# placement that AGENTS.md's Validation section documents. Run from
# anywhere inside the repository (or one of its worktrees):
#
#   ./scripts/linux-container-verify.sh                    # full RunPlayCoreTests, warning-clean
#   ./scripts/linux-container-verify.sh --filter RouteGroupingTests
#   ./scripts/linux-container-verify.sh podman --filter RouteGroupingTests
#
# The first optional argument may be the runtime to force (docker or
# podman); without it the runtime is auto-detected by probing each
# candidate binary — a `docker` that reports podman (the Fedora
# podman-docker shim) is driven with podman's flags. Remaining
# arguments are forwarded to `swift test`, which always runs warning-clean
# with the scratch tree at .build-linux (the two mandatory container
# properties — a non-root user that owns the mounted sources, and a
# writable HOME — are preserved; see AGENTS.md for why).
set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=".github/workflows/ci.yml"

# Resolve the CI container pin by its key and fail fast: the
# shape-documenting comment above the line matches a plain `swift:` grep,
# so anchor on `container:` — the same anchor check-toolchain-parity.sh
# uses — and reject anything that is not a digest-pinned tag.
IMAGE="$(awk '$1 == "container:" { print $2; exit }' "${WORKFLOW}")"
case "${IMAGE}" in
  swift:*@sha256:*[0-9a-f]) ;;
  *)
    echo "error: could not read the Swift container pin from ${WORKFLOW}" >&2
    echo "expected a job-level line of the shape 'container: swift:<major>.<minor>.<patch>-<codename>@sha256:<digest>'" >&2
    exit 1
    ;;
esac

RUNTIME="${1:-}"
RUNTIME_BIN=""
case "${RUNTIME}" in
  docker|podman) shift ;;
  *) RUNTIME="" ;;
esac

# Auto-detection must probe the binary, not trust its name. On Fedora hosts
# the podman-docker package installs /usr/bin/docker as a shim that execs
# podman, so `command -v docker` succeeds while the engine is rootless
# podman — and the docker branch below omits --userns=keep-id, which is
# exactly the failure this script exists to prevent. A genuine Docker
# reports "Docker version <n>, build <sha>"; the shim reports
# "podman version <n>".
reports_podman() {
  case "$("$1" --version 2>/dev/null || true)" in
    *[Pp]odman*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "${RUNTIME}" ]; then
  if command -v docker >/dev/null 2>&1 && ! reports_podman docker; then
    RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then
    # `docker` is the podman-docker shim and no separate `podman` binary is
    # on PATH: keep podman's flags, drive them through the shim.
    RUNTIME=podman
    RUNTIME_BIN=docker
  else
    echo "error: neither docker nor podman is installed" >&2
    exit 1
  fi
fi
[ -n "${RUNTIME_BIN}" ] || RUNTIME_BIN="${RUNTIME}"

# Writable HOME on the workspace filesystem: a host whose root filesystem
# is full fails a HOME=/tmp form before any test runs, with only an
# opaque SwiftPM "invalid access" error as the clue. .build-linux/ is
# gitignored, so the run still leaves git status --porcelain empty.
mkdir -p .build-linux/container-home

if [ $# -eq 0 ]; then
  set -- --filter RunPlayCoreTests
fi

# Runtime notes: `:Z` relabels the volume for SELinux-enforcing hosts and
# is accepted as a no-op elsewhere. Rootless podman needs --userns=keep-id
# — without it the container uid maps into the subuid range, /src appears
# root-owned, and the non-root user cannot write the checkout.
# ${RUNTIME_BIN} selects the flags and the binary together, so the
# podman-docker shim gets podman's flags.
case "${RUNTIME}" in
  docker)
    exec "${RUNTIME_BIN}" run --rm -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home -v "$PWD":/src:Z -w /src \
      "${IMAGE}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path .build-linux
    ;;
  podman)
    exec "${RUNTIME_BIN}" run --rm --userns=keep-id -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home -v "$PWD":/src:Z -w /src \
      "${IMAGE}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path .build-linux
    ;;
esac
