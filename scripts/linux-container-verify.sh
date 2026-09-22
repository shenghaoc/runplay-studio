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

# Remember whether this is the default full-suite invocation: the floor on
# tests that actually ran applies to it, and a narrower --filter legitimately
# runs fewer tests.
DEFAULT_FULL_SUITE=0
if [ $# -eq 0 ]; then
  set -- --filter RunPlayCoreTests
  DEFAULT_FULL_SUITE=1
fi

# Git refuses to operate in a repository whose ownership it cannot vouch
# for. A Docker Desktop bind mount on macOS does not satisfy that check
# even though -u matches the host uid, so the first run dies resolving the
# remote dependency:
#
#   fatal: detected dubious ownership in repository at
#   '/src/.build-linux/checkouts/ZIPFoundation'
#
# The exception must name the *checkout*, not the mount: safe.directory is
# an exact-path match, so a lone `/src` does not cover it (probed — it
# fails identically). `/src/*` is git's recursive form, which covers every
# dependency checkout under the scratch tree, and `/src` covers the
# worktree itself. Passed as container-scoped environment config so
# nothing on the host or in the repository is modified, and inert on hosts
# where the uid already owns the mount — which is why Linux CI, and podman
# with --userns=keep-id, never needed it.
GIT_SAFE_ENV=(
  -e GIT_CONFIG_COUNT=2
  -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/src
  -e GIT_CONFIG_KEY_1=safe.directory -e GIT_CONFIG_VALUE_1='/src/*'
)

# Runtime notes: `:Z` relabels the volume for SELinux-enforcing hosts and
# is accepted as a no-op elsewhere. Rootless podman needs --userns=keep-id
# — without it the container uid maps into the subuid range, /src appears
# root-owned, and the non-root user cannot write the checkout.
# ${RUNTIME_BIN} selects the flags and the binary together, so the
# podman-docker shim gets podman's flags.
case "${RUNTIME}" in
  docker)
    VIRTUALIZE=("${RUNTIME_BIN}" run --rm -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home "${GIT_SAFE_ENV[@]}" \
      -v "$PWD":/src:Z -w /src)
    ;;
  podman)
    VIRTUALIZE=("${RUNTIME_BIN}" run --rm --userns=keep-id -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home "${GIT_SAFE_ENV[@]}" \
      -v "$PWD":/src:Z -w /src)
    ;;
esac

# A check that silently skips suites cannot catch corelibs-only breakage.
# `swift test` exits 0 when a filter matches nothing, so neither the exit
# code nor a bare "0 failures" can distinguish a full run from a run that
# executed almost nothing. Assert the arithmetic instead: XCTest's
# `Executed N tests, with S skipped` counts skipped tests inside N (probed,
# not inferred: five test methods, three skipped, reports `Executed 5 tests,
# with 3 tests skipped`), so N - S is the number that genuinely ran.
#
# The headless container runs no benchmark bundle, so the only tests that may
# skip are the env-gated benchmarks: 16 on this suite. 900 sits well below the
# real ~1,080 executed and far above the ~0 a mass skip would leave, so it
# fails loudly on the latter and never on a normal count change.
FLOOR="${RUNPLAY_LINUX_MIN_EXECUTED:-900}"
MAX_SKIPPED="${RUNPLAY_LINUX_MAX_SKIPPED:-64}"

LOG=".build-linux/linux-container-verify.log"

echo "==> Linux container check"
echo "    image:    ${IMAGE}"
echo "    runtime:  ${RUNTIME}${RUNTIME_BIN:+ (via ${RUNTIME_BIN})}"
echo "    filter:   $*"
echo "    log:      ${LOG}"

set +e
"${VIRTUALIZE[@]}" "${IMAGE}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path .build-linux 2>&1 | tee "${LOG}"
STATUS="${PIPESTATUS[0]}"
set -e

if [ "${STATUS}" -ne 0 ]; then
  echo "==> swift test failed (exit ${STATUS})" >&2
  exit "${STATUS}"
fi

# Anchor on the aggregate summary line, not the first block: with a --filter,
# `swift test` still runs every bundle, and a filtered-out bundle prints
# `Executed 0 tests` first. XCTest only writes the skip clause when something
# skipped -- `Executed 36 tests, with 0 failures` with none, `Executed 1096
# tests, with 16 tests skipped and 0 failures` when some did -- so handle both
# and treat a missing clause as zero. Largest N is the aggregate.
SUMMARY="$(grep -oE 'Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures' "${LOG}" \
  | sed -E -e 's/.*Executed ([0-9]+) tests?, with ([0-9]+) tests? skipped and.*/\1 \2/' \
           -e 's/.*Executed ([0-9]+) tests?, with.*/\1 0/' \
  | sort -k1,1n | tail -1)"
if [ -z "${SUMMARY}" ]; then
  echo "==> could not find an 'Executed N tests, with ... failures' summary in the output" >&2
  exit 1
fi
EXECUTED="${SUMMARY% *}"
SKIPPED="${SUMMARY#* }"
RAN="$((EXECUTED - SKIPPED))"

echo "==> Executed ${EXECUTED}, skipped ${SKIPPED}, actually ran ${RAN}"

if [ "${DEFAULT_FULL_SUITE}" -eq 1 ]; then
  if [ "${RAN}" -lt "${FLOOR}" ]; then
    echo "==> FAIL: only ${RAN} tests actually ran (floor ${FLOOR})." >&2
    echo "    A green '0 failures' with almost nothing executed means the suite is being" >&2
    echo "    skipped -- the gate cannot prove corelibs compatibility this way." >&2
    exit 1
  fi
  if [ "${SKIPPED}" -gt "${MAX_SKIPPED}" ]; then
    echo "==> FAIL: ${SKIPPED} tests skipped (ceiling ${MAX_SKIPPED})." >&2
    echo "    Raise RUNPLAY_LINUX_MAX_SKIPPED only with a reason for the new skips." >&2
    exit 1
  fi
  echo "==> PASS: full suite ran ${RAN} tests (>= ${FLOOR}), ${SKIPPED} skipped (<= ${MAX_SKIPPED})"
else
  echo "==> filter given: floor not applied (this run is a subset by request)"
fi
