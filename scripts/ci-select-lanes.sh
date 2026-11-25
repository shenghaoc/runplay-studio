#!/usr/bin/env bash
# ci-select-lanes.sh — choose which CI lanes and test targets a pull request
# needs, from the paths it changes.
#
#   git diff --name-only --no-renames BASE HEAD \
#     | ./scripts/ci-select-lanes.sh --event pull_request >> "$GITHUB_OUTPUT"
#   ./scripts/ci-select-lanes.sh --self-test
#
# Prints three key=value lines:
#   linux=true|false             run the RunPlayCore (Linux) lane
#   macos=true|false             run the macOS verification lane
#   macos_test_filter=<regex>    `swift test --filter` value; empty means all
#                                test targets
#
# Module graph: RunPlayEngine -> RunPlayCore -> RunPlayPlatform ->
# RunPlayStudio. A change can reach only its own module and the modules
# downstream of it. Every path is classified and the widest result wins:
#
#   *.md outside RunPlay*/** and Tests/**, docs/**, prompts/**, LICENSE
#                                            nothing (lint still runs)
#   RunPlayStudio/**  (any file, *.md too)   macOS, Studio tests
#   RunPlayPlatform/**                       macOS, Platform + Studio tests
#   RunPlayCore/**, RunPlayEngine/**, any other
#   RunPlay*/**, Tests/**
#   (Package.swift, Package.resolved, scripts/**, script/**, .github/**,
#   Packaging/**, VERSION, and every path not listed above)
#                                            everything
#
# The selector fails open: an unlisted path, an empty or unreadable diff, or
# any event other than pull_request (the nightly reaches ci.yml through
# workflow_call) selects everything. Adding a module, or a test that reads a
# file outside its own module, means updating this script in the same PR.
#
# Bash 3.2 safe: no associative arrays, no mapfile, no case modification.
set -euo pipefail

FILTER_STUDIO='^RunPlayStudioTests\.'
FILTER_PLATFORM='^(RunPlayPlatformTests|RunPlayStudioTests)\.'

# classify PATH -> 0 nothing, 1 Studio, 2 Platform + Studio, 3 everything.
# The first matching pattern wins, so the module trees come before *.md.
classify() {
  case "$1" in
    RunPlayStudio/*) echo 1 ;;
    RunPlayPlatform/*) echo 2 ;;
    RunPlayCore/* | RunPlayEngine/*) echo 3 ;;
    RunPlay*/*) echo 3 ;; # a module this script does not know yet
    Tests/*) echo 3 ;;
    *.md | docs/* | prompts/* | LICENSE) echo 0 ;;
    *) echo 3 ;;
  esac
}

emit() {
  case "$1" in
    0) printf 'linux=false\nmacos=false\nmacos_test_filter=\n' ;;
    1) printf 'linux=false\nmacos=true\nmacos_test_filter=%s\n' "${FILTER_STUDIO}" ;;
    2) printf 'linux=false\nmacos=true\nmacos_test_filter=%s\n' "${FILTER_PLATFORM}" ;;
    *) printf 'linux=true\nmacos=true\nmacos_test_filter=\n' ;;
  esac
}

# select_lanes EVENT: reads one changed path per line on stdin.
select_lanes() {
  local event="$1" level=0 seen=0 path one
  if [ "${event}" != "pull_request" ]; then
    # Drain stdin so a writer upstream never dies of SIGPIPE under pipefail.
    cat > /dev/null || true
    emit 3
    return 0
  fi
  while IFS= read -r path || [ -n "${path}" ]; do
    # Blank lines carry no path; a diff of only blanks is an empty diff.
    if [ -z "${path//[[:space:]]/}" ]; then
      continue
    fi
    seen=1
    one="$(classify "${path}")"
    if [ "${one}" -gt "${level}" ]; then
      level="${one}"
    fi
  done
  if [ "${seen}" -eq 0 ]; then
    level=3 # empty diff: fail open
  fi
  emit "${level}"
}

self_test() {
  local failures=0 total=0 name event paths expect got want line
  # name | event | expected level (0-3) | paths separated by ';'
  local cases=(
    "docs only|pull_request|0|README.md;docs/architecture.md;docs/assets/demo-summary-light.png;AGENTS.md"
    "docs, prompts, license|pull_request|0|prompts/a.txt;LICENSE;docs/a/b.png"
    "md under .github|pull_request|0|.github/pull_request_template.md"
    "Studio only|pull_request|1|RunPlayStudio/Sources/Views/A.swift;RunPlayStudio/Tests/RunPlayStudioTests/ATests.swift"
    "Studio resource md follows its module|pull_request|1|RunPlayStudio/Resources/help.md"
    "Platform only|pull_request|2|RunPlayPlatform/Sources/Map/A.swift"
    "Platform plus Studio|pull_request|2|RunPlayPlatform/Sources/A.swift;RunPlayStudio/Sources/B.swift"
    "Core change|pull_request|3|RunPlayCore/Sources/Models/A.swift"
    "Core md is not docs-only|pull_request|3|RunPlayCore/Sources/README.md"
    "Unknown RunPlay module gives everything|pull_request|3|RunPlayEngineCpp/Sources/a.cpp"
    "Swift engine source|pull_request|3|RunPlayEngine/Sources/Geodesy.swift"
    "Swift engine tests|pull_request|3|RunPlayEngine/Tests/GeodesyTests.swift"
    "Swift engine test support|pull_request|3|RunPlayEngine/TestSupport/EngineParitySupport.swift"
    "Swift engine md is not docs-only|pull_request|3|RunPlayEngine/Sources/README.md"
    "Swift engine plus Studio gives everything|pull_request|3|RunPlayStudio/Sources/A.swift;RunPlayEngine/Sources/B.swift"
    "docs plus Swift engine gives everything|pull_request|3|docs/a.md;RunPlayEngine/Sources/B.swift"
    "Tests md is not docs-only|pull_request|3|Tests/PackageConsumerSmoke/NOTES.md"
    "package consumer smoke|pull_request|3|Tests/PackageConsumerSmoke/Package.swift"
    "Package.swift|pull_request|3|Package.swift"
    "Package.resolved|pull_request|3|Package.resolved"
    "scripts|pull_request|3|scripts/ci-select-lanes.sh"
    "workflow|pull_request|3|.github/workflows/ci.yml"
    "VERSION|pull_request|3|VERSION"
    "unknown top-level file|pull_request|3|.gitignore"
    "unknown module directory|pull_request|3|RunPlayFuture/Sources/a.swift"
    "rename Core to Studio counts both paths|pull_request|3|RunPlayCore/Sources/A.swift;RunPlayStudio/Sources/A.swift"
    "rename Studio to docs counts both paths|pull_request|1|RunPlayStudio/Sources/A.swift;docs/A.md"
    "docs plus Studio gives Studio|pull_request|1|docs/a.md;README.md;RunPlayStudio/Sources/A.swift"
    "Studio plus Core gives everything|pull_request|3|RunPlayStudio/Sources/A.swift;RunPlayCore/Sources/B.swift"
    "docs plus an unknown file gives everything|pull_request|3|docs/a.md;mystery.bin"
    "empty diff|pull_request|3|"
    "blank lines only|pull_request|3| ; "
    "schedule runs everything|schedule|3|docs/a.md"
    "workflow_dispatch runs everything|workflow_dispatch|3|README.md"
    "empty event runs everything||3|README.md"
  )
  for line in "${cases[@]}"; do
    total=$((total + 1))
    name="${line%%|*}"
    line="${line#*|}"
    event="${line%%|*}"
    line="${line#*|}"
    expect="${line%%|*}"
    paths="${line#*|}"
    want="$(emit "${expect}")"
    got="$(printf '%s\n' "${paths}" | tr ';' '\n' | select_lanes "${event}")"
    if [ "${got}" = "${want}" ]; then
      echo "    ok    ${name}"
    else
      echo "    FAIL  ${name}" >&2
      echo "      want: $(printf '%s' "${want}" | tr '\n' ' ')" >&2
      echo "      got:  $(printf '%s' "${got}" | tr '\n' ' ')" >&2
      failures=$((failures + 1))
    fi
  done
  if [ "${failures}" -ne 0 ]; then
    echo "==> ci-select-lanes self-test: ${failures} of ${total} cases failed" >&2
    return 1
  fi
  echo "==> ci-select-lanes self-test: ${total} cases passed"
}

usage() {
  echo "usage: $0 [--event NAME] < changed-paths | $0 --self-test" >&2
  echo "  --event NAME  the GitHub event; anything but pull_request selects everything" >&2
  echo "                (default: pull_request)" >&2
}

main() {
  local event="pull_request"
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        return $?
        ;;
      --event)
        if [ $# -lt 2 ]; then
          usage
          return 64
        fi
        event="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        usage
        return 64
        ;;
    esac
  done
  select_lanes "${event}"
}

main "$@"
