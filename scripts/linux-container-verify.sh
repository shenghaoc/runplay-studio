#!/usr/bin/env bash
# Single source of the local Linux container-verification invocation —
# the keyed pin read, shape guard, runtime flags, and HOME/scratch
# placement that AGENTS.md's Validation section documents. Run from
# anywhere inside the repository (or one of its worktrees):
#
#   ./scripts/linux-container-verify.sh                    # full RunPlayCoreTests, warning-clean
#   ./scripts/linux-container-verify.sh --filter RouteGroupingTests
#   ./scripts/linux-container-verify.sh podman --filter RouteGroupingTests
#   ./scripts/linux-container-verify.sh native             # already inside the pinned image (CI)
#
# The first optional argument may be the runtime to force (docker or
# podman), or `native` when the caller is already running inside the
# pinned image — the Linux CI job, whose `container:` key starts it — so
# `swift test` runs directly with the same gate applied. Without it the
# runtime is auto-detected by probing each candidate binary — a `docker`
# that reports podman (the Fedora podman-docker shim) is driven with
# podman's flags. Remaining
# arguments are forwarded to `swift test`, which always runs warning-clean
# with the scratch tree at .build-linux (.build in native mode) (the two mandatory container
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
  docker|podman|native) shift ;;
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

# Native mode measures the same thing the container recipe does only when
# the user is non-root: root bypasses POSIX permission bits
# (CAP_DAC_OVERRIDE), so the read-only-directory failure injection in
# testFailedWorkoutWritePreservesPriorValidData cannot fail and the test
# skips. Refuse rather than report a count that differs from a developer's.
# CI drops privileges with setpriv before calling this.
if [ "${RUNTIME}" = native ] && [ "$(id -u)" -eq 0 ]; then
  echo "error: native mode must run as a non-root user that owns the checkout" >&2
  echo "root bypasses POSIX permission bits, so permission-injection tests would skip" >&2
  exit 1
fi

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
      -v "$PWD":/src:Z -w /src "${IMAGE}")
    ;;
  podman)
    VIRTUALIZE=("${RUNTIME_BIN}" run --rm --userns=keep-id -u "$(id -u):$(id -g)" \
      -e HOME=/src/.build-linux/container-home "${GIT_SAFE_ENV[@]}" \
      -v "$PWD":/src:Z -w /src "${IMAGE}")
    ;;
  native)
    # Already inside the image: no wrapper, same writable HOME. There is no
    # host build tree to keep apart, so use the default scratch path and
    # reuse whatever the caller's earlier steps already built.
    #
    # TMPDIR too: SwiftPM keeps its scratch-tree lock in the temp directory
    # (/tmp/<mangled scratch path>.lock), not under the scratch tree, so a
    # root build earlier in the same container leaves a root-owned lock
    # there that the unprivileged user cannot open — CI's first run failed
    # with `invalid access to /tmp/___w_..._.build.lock`, and chowning the
    # checkout cannot reach it. Our own TMPDIR gives this user its own
    # locks; the caller's root builds have finished, so nothing contends.
    mkdir -p .build-linux/tmp
    VIRTUALIZE=(env HOME="$PWD/.build-linux/container-home" TMPDIR="$PWD/.build-linux/tmp")
    SCRATCH_PATH=.build
    ;;
esac
SCRATCH_PATH="${SCRATCH_PATH:-.build-linux}"

# A check that silently skips suites cannot catch corelibs-only breakage.
# `swift test` exits 0 when a filter matches nothing, so neither the exit
# code nor a bare "0 failures" can distinguish a full run from a run that
# executed almost nothing. Assert the arithmetic instead: XCTest's
# `Executed N tests, with S skipped` counts skipped tests inside N (probed,
# not inferred: five test methods, three skipped, reports `Executed 5 tests,
# with 3 tests skipped`), so N - S is the number that genuinely ran.
#
# FLOOR provenance: 900, against 1080 actually ran on current main
# (Executed 1096, skipped 16, non-root, swift:6.4.0-resolute). It is a
# loose floor whose job is only to catch a collapse to near-zero, which is
# what a mass `XCTSkip` looks like. It does not start to bite until
# RAN approx 150; the real lead time is ~2x. Keep the proportion by raising
# it in the PR that adds a batch of Core tests once RAN exceeds FLOOR + 200
# (i.e. at RAN > 1100 today), and never lower it to accommodate skips.
FLOOR="${RUNPLAY_LINUX_MIN_EXECUTED:-900}"

# SKIP REASONS ARE ALLOWLISTED, NOT COUNTED. A ceiling on the skip count
# (`64`) was the first design and was rejected: it does not catch
# mass-skipping (90 skips is under any bound loose enough to survive ordinary
# drift), and it rots as Core grows. The allowlist below does catch it and
# names the gap that tripped instead of just reporting that a number moved.
#
# Every reason observed in this container as a non-root user, all of which
# the pattern accepts:
#   RUNPLAY_BENCHMARK=1 / RUNPLAY_PRODUCTION_AB=1 / RUNPLAY_CORE_HOTSPOT_PROFILE=1
#   RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1 / RUNPLAY_HEATMAP_PROFILE=1
#   RUNPLAY_ROUTE_GROUPING_BENCHMARK=1 / RUNPLAY_ROUTE_GROUPING_MEASURE=1
#
# Deliberately NOT listed: testFailedWorkoutWritePreservesPriorValidData's
# "root bypasses POSIX permission bits" skip. Every entrypoint runs non-root
# (the container modes pass -u, native mode refuses uid 0, CI drops to a
# non-root uid), so that reason can only appear if one of them regressed to
# root — and then the permission-injection coverage is silently gone, which
# this gate should name rather than accept.
#
# To add a reason, put the newly-skipping test and its reason in the PR that
# introduces it; this check failing is the prompt to do that deliberately.
ALLOWED_SKIP_PATTERN='RUNPLAY_[A-Z_]+=1'

LOG=".build-linux/linux-container-verify.log"

echo "==> Linux container check"
if [ "${RUNTIME}" = native ]; then
  echo "    image:    ${IMAGE} (already inside it; not re-verified)"
else
  echo "    image:    ${IMAGE}"
fi
echo "    runtime:  ${RUNTIME}${RUNTIME_BIN:+ (via ${RUNTIME_BIN})} as uid $(id -u)"
echo "    filter:   $*"
echo "    log:      ${LOG}"

set +e
"${VIRTUALIZE[@]}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path "${SCRATCH_PATH}" 2>&1 | tee "${LOG}"
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

# Secondary guard: a collapse in the count of tests that ran. This does not
# rot in the sense the ceiling did -- a rising Core count only makes it more
# permissive, never falsely failing -- so it costs nothing to keep. It also
# sees what the allowlist cannot: a test class compiled out on Linux or
# dropped from the target disappears without printing a skip reason.
if [ "${DEFAULT_FULL_SUITE}" -eq 1 ]; then
  if [ "${RAN}" -lt "${FLOOR}" ]; then
    echo "==> FAIL: only ${RAN} tests actually ran (floor ${FLOOR})." >&2
    echo "    A drop in executed tests is a signal to investigate, not a number to raise." >&2
    echo "    ${FLOOR} is provenance-documented: the executed count on current main under the" >&2
    echo "    non-root container user, loose by design. Identify which tests stopped running" >&2
    echo "    and why before touching it." >&2
    exit 1
  fi

  # Primary guard, and the one that does not rot: every skip name must be a
  # reason this repo accepts. Mass-skipping is caught by name, and the failure
  # names the offending reason instead of only reporting that a count moved.
  #
  # corelibs XCTest prints a skip in two shapes, and both must be parsed:
  #   <file>:<line>: Class.test : Test skipped: required false value but got true - <msg>
  #                                            (XCTSkipIf / XCTSkipUnless)
  #   <file>:<line>: Class.test : Test skipped - <msg>
  #                                            (a bare `throw XCTSkip("<msg>")`)
  # #166 parsed only the colon form, so a bare XCTSkip was counted in S but
  # never checked -- CI's negative control (an unlisted bare XCTSkip) passed.
  # Reduce each to `Class.test<TAB><msg>`, then require one parsed reason per
  # skip XCTest reported: a third shape this does not know fails here
  # instead of slipping past the allowlist the way the dash form did.
  # awk, not sed: the container modes parse on the host, and BSD sed has no
  # \t in a replacement.
  SKIP_REASONS="$(awk 'match($0, / : Test skipped/) {
      n = split(substr($0, 1, RSTART - 1), head, ": ")
      msg = substr($0, RSTART + RLENGTH)
      sub(/^( -|:)? ?/, "", msg)
      sub(/^required (false|true) value but got (true|false) - /, "", msg)
      print head[n] "\t" msg
    }' "${LOG}")"
  PARSED="$(printf '%s' "${SKIP_REASONS}" | grep -c . || true)"
  if [ "${PARSED}" -ne "${SKIPPED}" ]; then
    echo "==> FAIL: XCTest reported ${SKIPPED} skipped, but ${PARSED} skip reasons were parsed." >&2
    echo "    A skip whose reason the gate cannot read cannot be checked against the" >&2
    echo "    allowlist. Teach the parser the new 'Test skipped' shape in ${LOG}." >&2
    exit 1
  fi
  UNKNOWN_SKIPS="$(printf '%s\n' "${SKIP_REASONS}" \
    | awk -F '\t' -v allowed="${ALLOWED_SKIP_PATTERN}" 'NF && $2 !~ allowed { print $1 ": " $2 }' \
    | sort -u)"
  if [ -n "${UNKNOWN_SKIPS}" ]; then
    echo "==> FAIL: ${SKIPPED} tests skipped, and at least one reason is not on the allowlist:" >&2
    printf '    %s\n' "${UNKNOWN_SKIPS}" >&2
    echo "    A RISE in skips is a signal to investigate. If the new skip is correct, add its" >&2
    echo "    reason to ALLOWED_SKIP_PATTERN in the PR that introduces the skipping test," >&2
    echo "    stating why -- do not widen the pattern to silence this." >&2
    exit 1
  fi
  echo "==> PASS: full suite ran ${RAN} tests (>= ${FLOOR}); ${SKIPPED} skipped, every reason allowlisted"
else
  echo "==> filter given: floor not applied (this run is a subset by request)"
fi
