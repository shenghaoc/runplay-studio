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

# A check that silently skips suites cannot catch corelibs-only breakage.
# `swift test` exits 0 when a filter matches nothing, so neither the exit
# code nor a bare "0 failures" can distinguish a full run from a run that
# executed almost nothing. Assert the arithmetic instead: XCTest's
# `Executed N tests, with S skipped` counts skipped tests inside N (probed,
# not inferred: five test methods, three skipped, reports `Executed 5 tests,
# with 3 tests skipped`), so N - S is the number that genuinely ran.
#
# FLOOR provenance: 1145, against 1208 actually run on the head that raised
# it (Executed 1225, skipped 17, non-root, swift:6.4.0-resolute) -- about 5%
# below the real count. The floor exists to catch tests that vanish WITHOUT printing a skip
# (a class compiled out under `#if os(macOS)` or a `canImport` guard false on
# corelibs, or dropped from the target), which the allowlist below cannot
# see. So it is tight on purpose: the headroom is room for a PR that
# legitimately deletes a few tests, not tolerance for drift. A PR that
# removes more than that lowers it deliberately and says why; never lower it
# to make a disappearance you have not explained pass. Raise it in the PR
# that adds Core tests once the headroom passes ~10% (RAN > ~1270 today),
# back to ~5% below the new count.
FLOOR="${RUNPLAY_LINUX_MIN_EXECUTED:-1145}"

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

# gate_log LOG FULL_SUITE FLOOR -- judge one `swift test` log. Returns 0 on
# pass, 1 on fail, printing why. A function so --self-test can run the
# identical code over checked-in logs; see self_test below.
gate_log() {
  local log="$1" full_suite="$2" floor="$3"
  local summary executed skipped ran skip_reasons parsed unknown_skips

  # Anchor on the aggregate summary line, not the first block: with a --filter,
  # `swift test` still runs every bundle, and a filtered-out bundle prints
  # `Executed 0 tests` first. XCTest only writes the skip clause when something
  # skipped -- `Executed 36 tests, with 0 failures` with none, `Executed 1096
  # tests, with 16 tests skipped and 0 failures` when some did -- so handle both
  # and treat a missing clause as zero. Largest N is the aggregate. The
  # `|| true` matters: with no summary line grep fails, and under pipefail
  # plus set -e that used to end the script before the message below.
  summary="$(grep -oE 'Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures' "${log}" \
    | sed -E -e 's/.*Executed ([0-9]+) tests?, with ([0-9]+) tests? skipped and.*/\1 \2/' \
             -e 's/.*Executed ([0-9]+) tests?, with.*/\1 0/' \
    | sort -k1,1n | tail -1 || true)"
  if [ -z "${summary}" ]; then
    echo "==> could not find an 'Executed N tests, with ... failures' summary in the output" >&2
    return 1
  fi
  executed="${summary% *}"
  skipped="${summary#* }"
  ran="$((executed - skipped))"

  echo "==> Executed ${executed}, skipped ${skipped}, actually ran ${ran}"

  if [ "${full_suite}" -ne 1 ]; then
    echo "==> filter given: floor not applied (this run is a subset by request)"
    return 0
  fi

  # Guard against silent disappearance: a test class compiled out on Linux or
  # dropped from the target prints no skip reason, so only the count of
  # tests that ran can see it. A rising Core count only makes this more
  # permissive, never falsely failing, so it does not rot.
  if [ "${ran}" -lt "${floor}" ]; then
    echo "==> FAIL: only ${ran} tests actually ran (floor ${floor})." >&2
    echo "    A drop in executed tests is a signal to investigate, not a number to lower." >&2
    echo "    Tests that vanish without a skip line (compiled out on Linux, dropped from" >&2
    echo "    the target) land here. Identify which stopped running and why first." >&2
    return 1
  fi

  # Guard against skipping: every skip reason must be one this repo accepts.
  # Mass-skipping is caught by name, and the failure names the offending
  # test and reason instead of only reporting that a count moved.
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
  skip_reasons="$(awk 'match($0, / : Test skipped/) {
      n = split(substr($0, 1, RSTART - 1), head, ": ")
      msg = substr($0, RSTART + RLENGTH)
      sub(/^( -|:)? ?/, "", msg)
      sub(/^required (false|true) value but got (true|false) - /, "", msg)
      print head[n] "\t" msg
    }' "${log}")"
  parsed="$(printf '%s' "${skip_reasons}" | grep -c . || true)"
  if [ "${parsed}" -ne "${skipped}" ]; then
    echo "==> FAIL: XCTest reported ${skipped} skipped, but ${parsed} skip reasons were parsed." >&2
    echo "    A skip whose reason the gate cannot read cannot be checked against the" >&2
    echo "    allowlist. Teach the parser the new 'Test skipped' shape in ${log}," >&2
    echo "    and add that shape to the --self-test fixtures." >&2
    return 1
  fi
  unknown_skips="$(printf '%s\n' "${skip_reasons}" \
    | awk -F '\t' -v allowed="${ALLOWED_SKIP_PATTERN}" 'NF && $2 !~ allowed { print $1 ": " $2 }' \
    | sort -u)"
  if [ -n "${unknown_skips}" ]; then
    echo "==> FAIL: ${skipped} tests skipped, and at least one reason is not on the allowlist:" >&2
    printf '    %s\n' "${unknown_skips}" >&2
    echo "    A RISE in skips is a signal to investigate. If the new skip is correct, add its" >&2
    echo "    reason to ALLOWED_SKIP_PATTERN in the PR that introduces the skipping test," >&2
    echo "    stating why -- do not widen the pattern to silence this." >&2
    return 1
  fi
  echo "==> PASS: full suite ran ${ran} tests (>= ${floor}); ${skipped} skipped, every reason allowlisted"
}

# The parser is shell + awk and has had two holes (the dash skip shape, and
# skips counted but never reason-checked), so it is tested like
# validate-cpp-boundaries.sh tests its helpers: fixtures with a pinned
# verdict, run before the gate is trusted. The two ci-*.log fixtures are
# real CI output from #172; the rest are synthetic, one per failure path.
# SELF_TEST_FLOOR is fixed, not FLOOR, so raising the policy value never
# re-judges historical logs; the clean log (1080) and below-floor (1000)
# bracket it. Runs on whatever awk is first on PATH: the macOS job covers
# BSD awk, and every Linux gate run covers the image's mawk.
SELF_TEST_DIR="scripts/fixtures/linux-container-verify"
SELF_TEST_FLOOR=1020
SELF_TEST_CASES=(
  # fixture | full suite | expected exit | expected output substring
  "ci-clean.log|1|0|==> PASS: full suite ran 1080 tests"
  "ci-probe-bare-xctskip.log|1|1|LinuxGateProbeSkipTests.testSkipsForAnUnlistedReason: PROBE unlisted skip reason"
  "allowlisted-skip-shapes.log|1|0|3 skipped, every reason allowlisted"
  "root-permission-skip.log|1|1|FileWorkoutLibraryStoreTests.testFailedWorkoutWritePreservesPriorValidData: root bypasses POSIX permission bits"
  "unparsed-skip-shape.log|1|1|XCTest reported 2 skipped, but 1 skip reasons were parsed"
  "below-floor.log|1|1|only 1000 tests actually ran (floor 1020)"
  "filtered-no-skip-clause.log|0|0|Executed 36, skipped 0, actually ran 36"
  "no-summary.log|1|1|could not find an 'Executed N tests"
)

self_test() {
  local case_spec fixture full expected_rc expected_text out rc failures=0
  for case_spec in "${SELF_TEST_CASES[@]}"; do
    IFS='|' read -r fixture full expected_rc expected_text <<<"${case_spec}"
    if out="$(gate_log "${SELF_TEST_DIR}/${fixture}" "${full}" "${SELF_TEST_FLOOR}" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    if [ "${rc}" -eq "${expected_rc}" ] && [[ "${out}" == *"${expected_text}"* ]]; then
      echo "    ok    ${fixture} (exit ${rc})"
    else
      echo "    FAIL  ${fixture}: expected exit ${expected_rc} with '${expected_text}', got exit ${rc}:" >&2
      printf '%s\n' "${out}" | sed 's/^/          /' >&2
      failures=$((failures + 1))
    fi
  done
  if [ "${failures}" -ne 0 ]; then
    echo "==> gate self-test: ${failures} of ${#SELF_TEST_CASES[@]} fixtures failed (awk: $(awk_identity))" >&2
    return 1
  fi
  echo "==> gate self-test: ${#SELF_TEST_CASES[@]} fixtures passed (awk: $(awk_identity))"
}

awk_identity() {
  local path
  path="$(command -v awk)"
  # BSD awk and gawk answer --version; mawk answers -W version.
  { awk --version 2>/dev/null || awk -W version 2>/dev/null; } | head -n1 | sed "s|^|${path}: |"
}

if [ "${1:-}" = --self-test ]; then
  self_test
  exit
fi


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

# Trust the parser only after it has judged its fixtures on this host's
# awk -- before the minutes-long test run, so a broken parser fails fast.
if ! SELF_TEST_OUTPUT="$(self_test 2>&1)"; then
  printf '%s\n' "${SELF_TEST_OUTPUT}" >&2
  exit 1
fi
printf '%s\n' "${SELF_TEST_OUTPUT}" | tail -n1

# SwiftPM itself can segfault in libdispatch while it plans the build (#199);
# the wrapper reruns `swift test` once for exactly that crash. It never reruns
# after SwiftPM printed `Build complete!`, so a retried attempt left no test
# output in the log, and gate_log below still judges a single run. Forwarded
# -q/--quiet or --skip-build hide that line, and turn the retry off.
set +e
./scripts/retry-swiftpm-libdispatch-crash.sh \
  "${VIRTUALIZE[@]}" swift test "$@" -Xswiftc -warnings-as-errors --scratch-path "${SCRATCH_PATH}" 2>&1 | tee "${LOG}"
STATUS="${PIPESTATUS[0]}"
set -e

if [ "${STATUS}" -ne 0 ]; then
  echo "==> swift test failed (exit ${STATUS})" >&2
  exit "${STATUS}"
fi

if gate_log "${LOG}" "${DEFAULT_FULL_SUITE}" "${FLOOR}"; then
  exit 0
fi
exit 1
