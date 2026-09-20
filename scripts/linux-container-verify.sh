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
# podman); without it the first available runtime wins. Remaining
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
case "${RUNTIME}" in
  docker|podman) shift ;;
  *) RUNTIME="" ;;
esac
if [ -z "${RUNTIME}" ]; then
  if command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  else
    echo "error: neither docker nor podman is installed" >&2
    exit 1
  fi
fi

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
case "${RUNTIME}" in
  docker)
    exec docker run --rm -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home -v "$PWD":/src:Z -w /src \
      "${IMAGE}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path .build-linux
    ;;
  podman)
    exec podman run --rm --userns=keep-id -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home -v "$PWD":/src:Z -w /src \
      "${IMAGE}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path .build-linux
    ;;
esac
