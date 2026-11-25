"""Report how many tests a macOS CI run executed, skipped and actually ran.

    python3 scripts/report-test-counts.py --label NAME --swift-test-log LOG
    python3 scripts/report-test-counts.py --label NAME --xcresult RESULT.xcresult

An exit code alone is not evidence: `swift test --filter` exits 0 when the
filter matches nothing, and a skipped test passes. So the run is reported as
`Executed N, skipped S, ran N-S` (AGENTS.md, Validation), and this script
fails when no test ran.

A `swift test` log carries two kinds of summary. XCTest prints one per test
bundle, after `Test Suite '<Target>.xctest' passed|failed`; its `Executed N`
counts skipped tests too. Swift Testing prints `Test run with N tests` per
run, where N also counts skipped tests, and one `➜ Test … skipped.` line per
skipped test. The figures are summed over both kinds.

An xcresult bundle is read with `xcrun xcresulttool get test-results
summary`: totalTestCount, skippedTests, failedTests.

With GITHUB_STEP_SUMMARY set, the line is also written to the job summary.
"""

import argparse
import json
import os
import re
import subprocess
import sys

XCTEST_BUNDLE = re.compile(r"^Test Suite '(?P<bundle>[^']+)\.xctest' (?:passed|failed) at ")
XCTEST_EXECUTED = re.compile(
    r"^\s*Executed (?P<executed>\d+) tests?, with (?:(?P<skipped>\d+) tests? skipped and )?"
    r"(?P<failed>\d+) failures?"
)
SWIFT_TESTING_RUN = re.compile(r"^\S+ Test run with (?P<executed>\d+) tests? ")
SWIFT_TESTING_SKIP = re.compile(r"^\S+ Test .* skipped\b")


def swift_test_counts(path):
    executed = skipped = failed = 0
    bundles = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    for index, line in enumerate(lines):
        bundle = XCTEST_BUNDLE.match(line)
        if bundle and index + 1 < len(lines):
            summary = XCTEST_EXECUTED.match(lines[index + 1])
            if summary:
                bundle_executed = int(summary.group("executed"))
                bundle_skipped = int(summary.group("skipped") or 0)
                executed += bundle_executed
                skipped += bundle_skipped
                failed += int(summary.group("failed"))
                bundles.append(f"{bundle.group('bundle')} {bundle_executed}/{bundle_skipped}")
            continue
        run = SWIFT_TESTING_RUN.match(line)
        if run:
            executed += int(run.group("executed"))
            continue
        if SWIFT_TESTING_SKIP.match(line):
            skipped += 1
    return executed, skipped, failed, bundles


def xcresult_counts(path):
    output = subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path, "--compact"],
        text=True,
    )
    summary = json.loads(output)
    return summary["totalTestCount"], summary["skippedTests"], summary["failedTests"], []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--swift-test-log")
    source.add_argument("--xcresult")
    args = parser.parse_args()

    try:
        if args.swift_test_log:
            executed, skipped, failed, bundles = swift_test_counts(args.swift_test_log)
        else:
            executed, skipped, failed, bundles = xcresult_counts(args.xcresult)
    except (OSError, subprocess.CalledProcessError, KeyError, ValueError) as error:
        print(f"{args.label}: could not read the test counts: {error}", file=sys.stderr)
        return 1

    ran = executed - skipped
    line = f"{args.label}: Executed {executed}, skipped {skipped}, ran {ran}, failed {failed}"
    if bundles:
        line += f" (XCTest bundles, executed/skipped: {', '.join(bundles)})"
    print(line)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(f"- {line}\n")
    if ran <= 0:
        print(f"{args.label}: no test ran", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
