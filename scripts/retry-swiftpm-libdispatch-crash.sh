#!/usr/bin/env bash
# Run one SwiftPM command and, only when SwiftPM itself died of the known
# upstream libdispatch crash before its build completed, run it once more
# (#199). Every SwiftPM build in the Linux CI lane goes through this, including
# the `swift test` inside scripts/linux-container-verify.sh:
#
#   ./scripts/retry-swiftpm-libdispatch-crash.sh swift build --package-path Tests/PackageConsumerSmoke
#   ./scripts/retry-swiftpm-libdispatch-crash.sh --self-test
#
# The crash: since Swift 6.4, SwiftPM builds through swift-build, which spawns
# tool-discovery processes (`clang -v` and the like) in parallel while
# pre-planning and reads their output through DispatchIO. libdispatch's Linux
# epoll backend can free a muxnote that epoll still delivers events for; the
# manager thread then segfaults in `_dispatch_event_loop_drain`, decoding the
# reused memory as a source's owner. It is SwiftPM that crashes, at
# `[Pre-planning 1 / N]` before anything compiles, whatever the package.
# Upstream: swiftlang/swift#87033 (this frame and register state, in
# swift-package) and swiftlang/swift-corelibs-libdispatch#949 (root cause and
# reproducer). When this was added, on Swift 6.4.0, no toolchain had a fix:
# src/event/event_epoll.c was unchanged on libdispatch main and on every
# release/6.4 branch, and 6.5-dev still crashed. The Swift 6.3 lane never hit
# it because its SwiftPM used the native build system.
#
# A command is retried only when all three hold; any other outcome is final.
#   1. It exited 139: the SwiftPM process itself died of SIGSEGV. A crashing
#      test binary does not qualify; `swift test` reports it as "exited with
#      unexpected signal code N" and exits 1.
#   2. The Swift runtime backtrace names `_dispatch_event_loop_drain` in
#      libdispatch.so as frame 0 of the crashed thread. Anywhere else it
#      proves nothing: an idle dispatch manager thread is parked one frame
#      below it in ordinary crash reports (ci-test-binary-crash.log is a real
#      test crash of that shape).
#   3. The output has no `Build complete!` (`Build of <subset> complete!` from
#      the native build system) line. SwiftPM prints it before `swift test`
#      runs a test and before `swift run` starts the product, so a retry never
#      re-runs anything that already ran and a test failure is final on the
#      first run. Never wrap a `--quiet` or `--skip-build` invocation: neither
#      prints the line, so this guard would be blind.
#
# One retry, never more. A retry posts a warning annotation (a plain `==>`
# line outside GitHub Actions) right after the first attempt's backtrace,
# which stays in the log, so how often this fires can be counted from run
# annotations. Delete this script and its call sites once the pinned image
# ships a libdispatch with #949 fixed; do not widen it to other failures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="swiftlang/swift#87033, swiftlang/swift-corelibs-libdispatch#949"

# known_crash LOG -- 0 when LOG shows conditions 2 and 3 above, 1 otherwise.
# Plain POSIX awk: it runs on the image's mawk, and on the host's awk (BSD awk
# on a Mac) under the docker and podman modes of linux-container-verify.sh.
# A thread header starts a section; only a crashed thread's section is
# searched for frame 0, which may sit below lines another writer interleaved.
# With several reports the last crashed thread wins: the process whose exit
# status this is, the wrapped SwiftPM process, is the last to report.
known_crash() {
  awk '
    { sub(/\r$/, "") }
    /Build (of [^!]* )?complete!/ { built = 1 }
    /^Thread [0-9]+[ :]/ { crashed = ($0 ~ /crashed:$/); if (crashed) frame0 = ""; next }
    /^(Registers|Images)[ :(]/ { crashed = 0 }
    crashed && $1 == "0" { frame0 = $0; crashed = 0 }
    END {
      if (!built && frame0 ~ /[ \t]_dispatch_event_loop_drain [+] [0-9]+ in libdispatch[.]so([ \t]|$)/) exit 0
      exit 1
    }
  ' "$1"
}

# annotate LEVEL TITLE MESSAGE -- a GitHub Actions annotation, with MESSAGE
# escaped per the workflow-command rules (TITLE is a fixed string that needs
# none); a plain line elsewhere.
annotate() {
  local message="$3"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    message="${message//\%/%25}"
    message="${message//$'\r'/%0D}"
    message="${message//$'\n'/%0A}"
    echo "::$1 title=$2::${message}"
  else
    echo "==> $2: ${message}"
  fi
}

# run_with_retry LOG COMMAND... -- run COMMAND with stderr merged into stdout,
# streamed through and captured in LOG, and run it once more if it died of the
# known crash. Returns the final attempt's exit status.
run_with_retry() {
  local log="$1" attempt status
  shift
  for attempt in 1 2; do
    set +e
    "$@" 2>&1 | tee "${log}"
    status="${PIPESTATUS[0]}"
    set -e
    if [ "${status}" -ne 139 ] || ! known_crash "${log}"; then
      return "${status}"
    fi
    if [ "${attempt}" -eq 1 ]; then
      annotate warning "Known SwiftPM crash retried" \
        "SwiftPM segfaulted in libdispatch _dispatch_event_loop_drain before the build completed (upstream ${UPSTREAM}); running it once more: $*"
    fi
  done
  annotate error "Known SwiftPM crash twice" \
    "SwiftPM hit the same libdispatch crash on its retry too; not retrying again (upstream ${UPSTREAM}): $*"
  return "${status}"
}

# The classifier and the loop are tested like linux-container-verify.sh tests
# its gate: fixtures with a pinned verdict. The ci-*.log fixtures are real CI
# output, timestamps stripped and trailing blanks trimmed: the two #199
# crashes (one preceded by the backtracer's own thread-suspend retry) and a
# test-binary crash from July. The rest are synthetic, one per rejection
# path. The loop runs fake_swiftpm, whose exit status per run is scripted.
SELF_TEST_DIR="${ROOT}/scripts/fixtures/retry-swiftpm-libdispatch-crash"
CLASSIFY_CASES=(
  # fixture | 0 = the known crash, 1 = anything else
  "ci-smoke-preplanning-crash.log|0"
  "ci-smoke-preplanning-crash-suspend-retry.log|0"
  "ci-test-binary-crash.log|1"
  "crash-after-build-complete.log|1"
  "crash-after-product-build-complete.log|1"
  "drain-on-idle-thread-only.log|1"
  "drain-below-frame-zero.log|1"
  "segfault-without-backtrace.log|1"
)
RETRY_CASES=(
  # fixture printed on failure | first exit | later exits | expected exit | expected runs | expected output
  "ci-smoke-preplanning-crash.log|139|0|0|2|::warning title=Known SwiftPM crash retried::"
  "ci-smoke-preplanning-crash.log|139|139|139|2|::error title=Known SwiftPM crash twice::"
  "ci-smoke-preplanning-crash.log|1|0|1|1|"
  "drain-on-idle-thread-only.log|139|0|139|1|"
  "ci-smoke-preplanning-crash.log|0|0|0|1|Build complete!"
)

# fake_swiftpm COUNTER FIXTURE FIRST LATER -- a SwiftPM stand-in: counts its
# runs in COUNTER and exits FIRST on the first run and LATER after, printing
# FIXTURE when that status is a failure and a finished build otherwise.
fake_swiftpm() {
  local runs status
  runs="$(( $(cat "$1" 2>/dev/null || echo 0) + 1 ))"
  echo "${runs}" > "$1"
  status="$4"
  [ "${runs}" -gt 1 ] || status="$3"
  if [ "${status}" -eq 0 ]; then
    echo "Build complete! (0.01 secs)"
  else
    cat "$2"
  fi
  return "${status}"
}

self_test() {
  local tmp="$1" spec fixture expected first later want_rc want_runs want_text
  local rc out runs failures=0 total=0
  for spec in "${CLASSIFY_CASES[@]}"; do
    IFS='|' read -r fixture expected <<<"${spec}"
    total=$((total + 1))
    rc=0
    known_crash "${SELF_TEST_DIR}/${fixture}" || rc=$?
    if [ "${rc}" -eq "${expected}" ]; then
      echo "    ok    classify ${fixture} (${rc})"
    else
      echo "    FAIL  classify ${fixture}: expected ${expected}, got ${rc}" >&2
      failures=$((failures + 1))
    fi
  done
  for spec in "${RETRY_CASES[@]}"; do
    IFS='|' read -r fixture first later want_rc want_runs want_text <<<"${spec}"
    total=$((total + 1))
    rm -f "${tmp}/runs"
    rc=0
    out="$(GITHUB_ACTIONS=true run_with_retry "${tmp}/log" \
      fake_swiftpm "${tmp}/runs" "${SELF_TEST_DIR}/${fixture}" "${first}" "${later}" 2>&1)" || rc=$?
    runs="$(cat "${tmp}/runs" 2>/dev/null || echo 0)"
    if [ "${rc}" -eq "${want_rc}" ] && [ "${runs}" -eq "${want_runs}" ] && [[ "${out}" == *"${want_text}"* ]]; then
      echo "    ok    retry ${fixture}, exiting ${first} then ${later}: exit ${rc} after ${runs} run(s)"
    else
      echo "    FAIL  retry ${fixture}, exiting ${first} then ${later}: expected exit ${want_rc} after ${want_runs} run(s) printing '${want_text}', got exit ${rc} after ${runs}:" >&2
      # The prefix keeps a captured annotation from becoming a real one.
      printf '%s\n' "${out}" | tail -n 5 | sed 's/^/          | /' >&2
      failures=$((failures + 1))
    fi
  done
  total=$((total + 1))
  out="$(GITHUB_ACTIONS=true annotate warning T $'100% of %0A\r\nnext')"
  if [ "${out}" = "::warning title=T::100%25 of %250A%0D%0Anext" ]; then
    echo "    ok    annotation escaping"
  else
    echo "    FAIL  annotation escaping, got:" >&2
    printf '%s\n' "${out}" | sed 's/^/          | /' >&2
    failures=$((failures + 1))
  fi
  if [ "${failures}" -ne 0 ]; then
    echo "==> retry self-test: ${failures} of ${total} cases failed (awk: $(awk_identity))" >&2
    return 1
  fi
  echo "==> retry self-test: ${total} cases passed (awk: $(awk_identity))"
}

awk_identity() {
  local path
  path="$(command -v awk)"
  # BSD awk and gawk answer --version; mawk answers -W version.
  { awk --version 2>/dev/null || awk -W version 2>/dev/null; } | head -n1 | sed "s|^|${path}: |"
}

if [ "${1:-}" = --self-test ]; then
  SELF_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/retry-swiftpm-self-test.XXXXXX")"
  trap 'rm -rf "${SELF_TEST_TMP}"' EXIT
  self_test "${SELF_TEST_TMP}"
  exit
fi

if [ "$#" -eq 0 ]; then
  echo "usage: $0 COMMAND [ARGUMENT...]   (a command that runs swift build, test or run)" >&2
  echo "   or: $0 --self-test" >&2
  exit 2
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/retry-swiftpm.XXXXXX")"
trap 'rm -f "${LOG}"' EXIT
STATUS=0
run_with_retry "${LOG}" "$@" || STATUS=$?
exit "${STATUS}"
