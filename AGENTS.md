# AGENTS.md — RunPlay Studio

RunPlay Studio is a native macOS application for local, post-run GPS workout
visualization, replay, analysis, comparison, and export. It is not a live
tracker, cloud service, social network, web app, or AI product.

This is the canonical operating contract for every coding agent. It supersedes
historical rapid-prototyping prompts that instructed agents to work directly on
`main` or leave transient handoff status in committed documentation.

## Instruction Hierarchy

1. Source code, tests, `Package.swift`, and CI workflows are executable truth.
2. This root `AGENTS.md` defines repository operating policy.
3. Linked documentation provides detailed reference material.
4. Tool entrypoints—including Claude, Gemini, Copilot, and Kiro steering—must
   defer to this file and must not duplicate or override policy.
5. `.jules/` files are advisory historical learnings. `.kiro/specs/` files are
   task artifacts. Neither overrides this file or executable truth.

When prose conflicts with implementation, inspect the implementation, tests,
and CI. Correct durable documentation drift in the same change when relevant;
do not silently follow stale prose.

## Agent Startup

Before editing:

1. Read this file and only the detailed references relevant to the task.
2. Run `git status --short`; never discard unexplained user or agent changes.
3. Fetch `origin`, confirm the current branch, merge base, and assigned PR.
4. Inspect the affected implementation and tests before proposing a change.
5. Run the narrowest relevant baseline verification command.
6. Open or update a draft PR with its scope and explicit non-goals before
   implementation work becomes broad.

## Branch, Worktree, And PR Rules

- **Never commit directly to `main` and never rewrite or force-push it.**
- One task equals one branch, one worktree, and one PR. Do not let agents share
  a checkout or branch.
- Start new work from current `origin/main` in a dedicated worktree, for example:

  ```bash
  git fetch origin
  git worktree add -b <type>/<short-task> ../runplay-<task> origin/main
  cd ../runplay-<task>
  ```

- Rebase only the branch you own. Use `--force-with-lease` only when publishing
  your own rebased branch after checking its live remote head; never force-push
  `main`.
- Do not rebase, reset, amend, clean, force-push, merge, or delete another
  agent's branch or worktree without the owner's explicit direction.
- Make small logical commits and push useful checkpoints to the feature branch.
- Open a draft PR early. Record objective, scope, non-goals, validation actually
  run, remaining manual checks, and dependent or conflicting PRs in the PR body.
  Use comments for interim coordination.
- Do not create handoff-only commits or store current commit hashes in committed
  documentation. `git log`, the live PR, and CI are the current-state sources.
- Before taking over an existing PR: read its body and comments, inspect the live
  head, branch diff, review threads, and CI; update the PR handoff before changing
  scope. After merge, remove only your own worktree and local branch when no
  longer needed.

## Parallel-Agent Safety

- Each PR must declare its intended files or subsystem. Avoid unrelated nearby
  cleanup.
- Serialize changes to shared coordination files: `AGENTS.md`, `Package.swift`,
  CI workflows, `AppState`, shared architecture documents, and Kiro steering.
- Do not overwrite unexplained changes or resurrect commits removed by a history
  cleanup.
- After rebasing onto updated `main`, rerun the relevant verification suite.

## Architecture Boundaries

Dependency direction is:

```text
RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngineCpp
```

Reverse dependencies are forbidden. `RunPlayPlatform` and `RunPlayStudio` must
not import `RunPlayEngineCpp` directly.

- **RunPlayEngineCpp** is the portable C++23 computational engine. It uses only
  the C++ standard library (no Apple frameworks, Foundation, Objective-C, or
  third-party deps). It currently exposes engine identity, route input values,
  one synchronous route-batch inspection boundary, allocation-free geodesy
  primitives (coordinate validation, Haversine distance, local-metre
  projection), the
  production combined route-quality geometry kernel, the production
  per-workout personal heatmap coverage kernel, the production
  constrained-DTW path solver for Route-Aware comparison, the production
  SegmentDetector window-search kernel, and the production ElevationProfile
  multi-pass construction kernel, plus production route-metric scale and
  bucket finalization. C++23 performs production
  outlier evidence, isolated-point rejection, implicit gap inference, final
  segment compaction, supplied-distance policy, and normalized cumulative
  distances through one bulk call. Swift still owns stage-1 validation and
  source-speed checks. For the personal heatmap, C++23 performs
  Web Mercator projection, grid-cell quantization, effective-segment gap
  breaking, supercover interval traversal, per-workout cell de-duplication, and
  deterministic cell ordering through one bulk call per workout; Swift still
  owns date filtering, the adaptive resolution loop, cross-workout aggregation,
  the minimum-workout-count filter, and snapshot finalization. Interop consumes
  the caller-owned native cell buffer through a private nonescaping closure and
  increments the Swift cross-workout dictionary directly; production creates no
  per-workout Swift cell array. The dictionary uses bounded reservation hints,
  not a product limit, and `PersonalHeatmapCellID` equality and `Codable`
  identity remain the original X/Y pair. For Route-Aware comparison, C++23
  performs the bounded band-packed constrained-DTW path solve
  — band radius, packed row layout, band-cell budget validation, geometry-only
  point cost, open prefix/suffix seeding, constrained transitions with fixed tie
  priority, consecutive-warp capping, endpoint selection, and path
  reconstruction — through one bulk call per alignment attempt. No scalar
  per-point Swift/C++ production calls are allowed. For segment detection,
  C++23 performs the distance-window searches for fastest 400m, fastest/slowest
  1km, biggest climb/descent, and the five fixed-distance personal-record
  windows (fastest 1 mile, 5 km, 10 km, half marathon, marathon) through one
  bulk call per `SegmentDetector` invocation. Swift retains policy
  calculation, public `SegmentHighlight` and `PersonalRecordWindow`
  construction, UUIDs, titles, subtitles, final range metadata, HR averages,
  cancellation, diagnostics, and persistence. For
  elevation construction, C++23 performs the complete multi-pass
  `ElevationProfile` build — source altitude screening, endpoint and isolated
  spike rejection, short-excursion rejection, supported rejected-sample
  interpolation, continuous altitude-run identification, reliable-run
  classification, distance-domain smoothing, cumulative corrected signed
  change, reliable-interval counting, and deadband-confirmed cumulative
  ascent/descent — through one bulk call per profile build. Swift retains
  route-point UUIDs, public `ElevationProfile`/`ElevationProfileSample`
  models, all distance-query APIs, policy ownership, cancellation,
  diagnostics, and persistence. For pace and heart-rate route-metric profiles,
  C++23 performs deterministic distance-weighted lower/median/upper scale
  construction, numeric normalization, bucket assignment, and numeric summary
  construction through one bulk call per profile finalization, using a
  caller-owned typed eligible workspace buffer plus a caller-owned output
  buffer. Corrected-elevation scale/bucket finalization intentionally remains
  in Swift because production A/B showed a native regression above the hard
  gate; that is mode-owned ownership, not an error-driven fallback. Swift
  retains raw pace, heart-rate, and corrected-elevation extraction,
  distance-domain smoothing, scale direction, localized labels, public
  route-metric models, availability and caching, Platform line coalescing,
  cancellation, diagnostics, UI state, and persistence. For heart-rate training
  load, C++23 performs interval-weighted Banister TRIMP accumulation and
  five-zone time bucketing through one bulk call per training-load pass over a
  Swift-built array of same-segment heart-rate intervals. Swift retains
  interval construction from route points (active-time weights that never span
  a recording gap or pause), the athlete-profile policy (resting/max heart
  rate, coefficient set, zone bounds), the measured-versus-estimated decision,
  the pace/duration estimator, public models, cancellation, and persistence.
- **RunPlayCore** is the stable Swift-facing core facade: domain models,
  `Codable` compatibility, Swift errors/diagnostics, actors and concurrency
  adaptation, filesystem persistence, schema migration, and translation
  between Swift models and C++ engine values. It depends on
  `RunPlayEngineCpp` via an internal Interop adapter. C++ types must not
  appear in public `RunPlayCore` APIs. Core remains cross-platform Foundation
  logic with conditional `FoundationXML`; it must not import UI, map,
  graphics, Core Location, or Combine. Swift continues to own route-size
  validation, basic field sanitization, sorting, initial source-segment
  compaction, source-speed validation, diagnostics translation,
  public models, and persistence. For Route-Aware comparison, Swift continues
  to build the compact alignment samples (at most 2,000 per route), detect
  route direction, construct alignment blocks from the returned index path,
  calculate diagnostics and quality, maintain the in-memory cache and task
  lifecycle, and publish the public alignment models. Use `GeoDistance` for
  remaining Swift geodesy stages, not `CLLocation`.
- **RunPlayPlatform** contains macOS non-SwiftUI adapters for SceneKit, AppKit,
  MapKit, and non-UI Combine. It must not depend on `RunPlayStudio`.
- **RunPlayStudio** owns SwiftUI, Charts, app lifecycle, GUI state, and UI
  export.

See [docs/architecture.md](docs/architecture.md) and
[Package.swift](Package.swift) for the live architecture and package graph.

### C++ engine policy (defaults)

Allowed and encouraged in `RunPlayEngineCpp`: value semantics, RAII,
`std::vector`, `std::span`, `std::array`, `std::optional`, `std::expected`
internally, `std::unique_ptr` where ownership cannot be a value, `enum class`,
`std::chrono`, ranges and algorithms, concepts where they simplify constraints.

Requires explicit justification: `std::shared_ptr`, raw non-owning pointers,
`reinterpret_cast`, mutable global state, exceptions in engine logic, manual
memory management.

Forbidden across the Swift boundary: uncaught exceptions, temporary borrowed
views, ownership ambiguity, `std::tuple`, `std::variant`, template-heavy public
APIs, callbacks into Swift, per-element cross-language calls.

Public Swift-facing C++ headers must not expose `std::vector`, `std::pair`,
`std::tuple`, or `std::variant`. A value-returning engine function must name its
fields through a standard-layout aggregate, as `LocalMeters` does, so Swift
reads documented members rather than positional elements.

Approved pointer boundaries:

- `const RouteInputSample*` input for route inspection
- combined route-quality geometry:

  * `const RouteInputSample*` input samples
  * optional `const std::uint8_t*` selection buffer
  * `RouteQualityOutputSample*` caller-owned output

- per-workout personal heatmap coverage:

  * `const PersonalHeatmapRouteSample*` input samples
  * `PersonalHeatmapCellIndex*` caller-owned output

- constrained-DTW path solving:

  * `const RouteAlignmentCostSample*` primary and comparison inputs plus a
    caller-owned `RouteAlignmentDtwPathCell*` output

- segment detection:

  * `const SegmentDetectionSample*` input samples
  * `SegmentWindowCandidate*` caller-owned output

- elevation profile construction:

  * `const ElevationProfileInputSample*` input samples
  * `ElevationProfileOutputSample*` caller-owned output

- route-metric scale/bucket assignment (pace and heart-rate production):

  * `const RouteMetricScaleBucketInputSample*` input samples
  * `RouteMetricScaleBucketWorkspaceSample*` caller-owned eligible workspace
  * `RouteMetricScaleBucketOutputSample*` caller-owned output

- heart-rate training load:

  * `const TrainingLoadSample*` input samples
  * no output pointer — aggregates return by value in `TrainingLoadSummary`

Swift owns every buffer. C++ borrows them synchronously. C++ retains nothing
and performs no callback.

Per-sample boundaries write exactly `sample_count` output entries on success
and write nothing on error. The personal heatmap coverage boundary is instead
capacity-negotiated: its output is a de-duplicated cell set whose size is not
known in advance, so it writes exactly `required_cell_count` entries on
success, and on `insufficient_output_capacity` it writes nothing while
reporting `required_cell_count` so Swift can reallocate and retry.
After success, Swift consumes only the written prefix while the caller-owned
buffer is alive; the native pointer never escapes Interop and C++ retains
nothing. The array-returning Swift adapter is compatibility/test-focused, not
the production builder path.

The constrained-DTW path boundary writes exactly `written_path_count` entries
on success. It is not capacity-negotiated: a valid path never exceeds
`primary_sample_count + comparison_sample_count + 1` cells, so Swift allocates
that proven upper bound and an insufficient-capacity response is an engine
contract violation rather than a retry signal. On any failure status the output
buffer is left completely unchanged. Alignment sample count is bounded in Swift
(`RouteAlignmentPolicy.maximumSamplesPerRoute`, 2,000 per route) and the solve
is bounded by `maximumBandCells` (4,000,000), checked both as an estimate before
allocation and exactly after the packed row layout is built. One native call
occurs per alignment attempt; none occurs per dynamic-programming row or cell.
Cancellation is cooperative Swift work checked before and after the native call
and during conversion and output translation, never inside the native call.

The segment-detection boundary writes exactly `candidate_count` entries on
success, where `candidate_count` is at most ten: the five segment-highlight
kinds plus one candidate per personal-record window that the route actually
covers. Swift always supplies the fixed ten-entry capacity; insufficient
capacity is an engine contract violation rather than a retry signal. On any
failure status the output buffer is left completely unchanged. The eight
internal searches (fastest 400m, combined one-kilometre pace, five
personal-record windows, and combined elevation) each retain the existing
per-search evaluation bound. One native call occurs per `SegmentDetector`
invocation, with cooperative Swift cancellation during conversion and before
and after the native call.

The elevation-profile boundary writes exactly `sample_count` output entries on
success (one-to-one with inputs). After validation the caller-owned output
buffer is the route-sized workspace; no route-sized native heap allocation is
performed. On any failure status the output buffer is left completely
unchanged. One native call occurs per `ElevationProfile.build`; none occurs per
sample, altitude run, smoothing window, or ascent/descent interval.
Cancellation is cooperative Swift work during conversion, immediately before
and after the native call, and during output translation — never inside the
native call.

The training-load boundary is summary-only: it takes `const TrainingLoadSample*`
plus a count and a by-value policy, and returns every product of the pass
(Banister TRIMP, five-zone seconds, valid and covered time, interval counts) in
a `TrainingLoadSummary` by value. No output buffer exists, and an error summary
carries no partial values — every numeric field is zero and only the status is
set. One native call occurs per training-load pass; none occurs per interval.
Cancellation is cooperative Swift work before and after the native call and
during input conversion, never inside the native call.

Supported workout size is bounded in Swift, never at the engine boundary.
`WorkoutImportResourceLimits` defines the product limits once — 1,000,000 route
points per resulting workout and a 100 MB source payload — and every importer
plus the `RouteQualityProcessor` preflight reads them from there. The engine's
`max_route_input_samples` is an internal safety ceiling 25% above the product
limit, so a route the app accepts can never be rejected by the engine. Raising
the product limit requires raising that ceiling to preserve the margin; a
parity test enforces the relationship. Do not add a second copy of either
number to an importer.

Migrated numerical code is a literal translation until a change of behaviour is
explicitly decided. Preserve constants, operation order, and existing
limitations, and split statements where needed so `-ffp-contract` cannot fuse a
multiply-add that Swift performs as two rounded operations.

## Project Invariants

- Do not add a third-party dependency without explicit owner approval and
  license review.
- Keep the app local-only. Do not add an app-operated backend, accounts,
  telemetry, analytics, cloud sync, or AI API without an explicit product
  decision.
- Never commit real workout data, screenshots, or exports. Private dogfood
  files belong only in ignored `local-workouts/` or `private-workouts/` paths;
  committed fixtures and demo assets must be synthetic or anonymized.
- Use explicit `git add <path>` for changes that could include local data.
  Before committing, inspect `git status --short` and
  `git diff --cached --name-status`.

See [docs/private-data.md](docs/private-data.md) and
[docs/privacy.md](docs/privacy.md) for detail.

## Change Discipline

- Make the smallest coherent change that satisfies the assigned task.
- Preserve public APIs unless the task explicitly changes them.
- Add or update focused tests for behavior changes.
- When an assertion looks GUI-only, first extract the underlying computation
  (geometry, membership, formatting, ordering) from the view into a pure
  helper and unit-test it; reserve GUI automation and manual passes for what
  only eyes can judge — layout, timing feel, and VoiceOver output.
- Do not claim GUI, format, platform, or workflow support without verification;
  report the actual command or manual boundary instead.
- Keep documentation tied to durable behavior, never transient branch status.

## Kiro

Kiro is the primary development environment for this repository. Codex,
Claude Code, Gemini CLI, GitHub Copilot, and other agents remain supported
through the same canonical contract.

**Steering** (`.kiro/steering/`) supplies scoped Kiro context under this
canonical policy. Steering files use `inclusion: always`, `inclusion:
fileMatch`, or `inclusion: auto` to inject the right context at the right time.
Keep durable repository facts in source, tests, `Package.swift`, CI, this file,
or the relevant `docs/` reference; use `#[[file:...]]` references so steering
does not become a competing copy.

**Specs** (`.kiro/specs/`) are task artifacts: one spec per branch per PR.
Keep requirements, design, and tasks scoped to the PR. Checked task boxes do
not prove completion — tests and CI do. Specs must not contain private data,
secrets, transient commit hashes, or repository-wide handoff status. Parallel
spec tasks must not edit the same shared files concurrently.

**Hooks** may be added to `.kiro/hooks/` when they provide genuine workflow
value. Keep hooks narrowly scoped and document their trigger and action in the
hook file; do not use hooks to bypass review or silently mutate shared files.

**Kiro CLI custom agents** live in `.kiro/agents/`. The checked-in
`runplay-cli.json` is a thin project adapter: it loads this file and workspace
steering explicitly, exposes only the tools needed for repository work, and
pre-approves read-only access only. Do not pin a model or duplicate repository
policy in an agent configuration.

**Durable learnings** live in `.jules/`: `bolt.md` for performance,
`palette.md` for accessibility, `sentinel.md` for security. Add a concise
dated entry only for a concrete reusable finding and its preventive action.
Do not use these files for task status, speculative advice, or copied policy.
Jules must use the lowercase `.jules/` directory only; never create or write
to a case-variant such as `.Jules/`.

## Validation

Use the same warning-clean SwiftPM commands enforced by CI:

```bash
./scripts/validate-cpp-boundaries.sh
swift build --target RunPlayEngineCpp \
  -Xcxx -Wall -Xcxx -Wextra -Xcxx -Wpedantic \
  -Xcxx -Wconversion -Xcxx -Wsign-conversion -Xcxx -Wshadow
swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors
./scripts/run-cpp-engine-tests.sh
./scripts/run-cpp-engine-tests.sh --sanitize   # ASan + UBSan on native C++ tests
swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors
swift build --package-path Tests/PackageConsumerSmoke
swift test --filter RunPlayPlatformTests -Xswiftc -warnings-as-errors  # macOS
swift test -Xswiftc -warnings-as-errors                               # macOS full stack
git diff --check
```

The smoke-consumer entry is platform-asymmetric, and the ignore rule
covering it is load-bearing: SwiftPM prunes unused package
dependencies per-product at build planning but per-package at
resolution. The consumer uses only the `RunPlayCore` product, so on
macOS `swift build --package-path Tests/PackageConsumerSmoke` still
resolves ZIPFoundation through the root path dependency and writes an
ignored `Tests/PackageConsumerSmoke/Package.resolved` pinning it — the
library itself is never compiled. On Linux the same graph is pruned
before resolution and no lockfile is written. Testing on Linux alone
therefore cannot show this rule working; do not remove it as dead code.

One warning is expected and accepted: while SwiftPM compiles
ZIPFoundation's own `Package@swift-5.9.swift` manifest it emits a
watchOS `.v4` deprecation warning (`'v4' is deprecated: watchOS 9.0 is
the oldest supported version`). It appears on macOS and Linux alike,
only in cold workspaces — every fresh CI runner, not local warm
builds — and `-Xswiftc -warnings-as-errors` cannot catch it because it
is a dependency-manifest diagnostic, not target compilation. It is
upstream's to fix; do not re-investigate.

Isolated verification runs: Swift 6.4 SwiftPM has no
`--manifest-cache-path` (rejected at every command level) and keeps
the manifest cache under `--cache-path`, so redirecting `--cache-path`
covers both. `swift build` and `swift test` accept `--scratch-path` as
a direct option, but `show-dependencies` and `resolve` accept it (and
`--cache-path`) only before the subcommand:
`swift package --scratch-path X --cache-path Y <subcommand>`.

RunPlayCore changes must verify the Linux build in a container before
pushing. Linux CI is Docker-only by policy: the CI job runs inside the
official Swift image pinned by the single `container:` line in
[.github/workflows/ci.yml](.github/workflows/ci.yml), and local
verification must use that exact image, read from the same pin so the
two cannot drift (currently `swift:6.4.0-resolute@sha256:bb6e5d…a91dc`,
an Ubuntu 26.04 userspace). Read the pin by its key and fail fast — the
comment block above the line documents the required *shape* and that
literal matches a plain `swift:` grep, so `grep 'swift:' | head -n1`
silently extracts the placeholder instead of the pin
(`scripts/check-toolchain-parity.sh` anchors on the same key and has
never had this problem):

```bash
IMAGE="$(awk '$1 == "container:" { print $2; exit }' .github/workflows/ci.yml)"
case "${IMAGE}" in
  swift:*@sha256:*[0-9a-f]) ;;
  *)
    echo "error: could not read the Swift container pin from .github/workflows/ci.yml" >&2
    echo "expected a job-level line of the shape 'container: swift:<major>.<minor>.<patch>-<codename>@sha256:<digest>'" >&2
    exit 1
    ;;
esac
mkdir -p .build-linux/container-home   # writable HOME, same filesystem as the workspace
```

Two properties are mandatory, and both runtime blocks below preserve
them:

1. The container user must be non-root and must own the mounted sources.
   The default container user is root, and root bypasses POSIX permission
   bits (CAP_DAC_OVERRIDE): filesystem-permission failure injection (for
   example a 0o555 read-only directory) then never fails, and tests report
   false "did not throw" failures.
2. HOME must be writable. A non-root uid has no passwd entry, so HOME
   resolves to `/` and SwiftPM fails with `invalid access to
   /.cache/org.swift.swiftpm`. HOME lives at
   `/src/.build-linux/container-home` — inside the already-ignored
   `.build-linux/` tree (`.gitignore` covers it, so the run still leaves
   `git status --porcelain` empty) — so the SwiftPM cache shares the
   workspace filesystem; a host whose root filesystem is full fails a
   `HOME=/tmp` form before any test runs, with only that opaque SwiftPM
   error as the clue.

docker:

```bash
docker run --rm -u $(id -u):$(id -g) -e HOME=/src/.build-linux/container-home \
  -v "$PWD":/src:Z -w /src "${IMAGE}" \
  swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors --scratch-path .build-linux
```

rootless podman — `--userns=keep-id` is required, not optional: without
it the container uid maps into the subuid range, `/src` appears
root-owned, and the non-root user cannot write the checkout (the failure
surfaces as SwiftPM `invalid access to /src/.build-linux/repositories`).
`--userns=keep-id` is podman-specific and rejected by docker, which is
why there are two blocks instead of one:

```bash
podman run --rm --userns=keep-id -u $(id -u):$(id -g) -e HOME=/src/.build-linux/container-home \
  -v "$PWD":/src:Z -w /src "${IMAGE}" \
  swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors --scratch-path .build-linux
```

`:Z` relabels the volume for SELinux-enforcing hosts and is accepted as
a no-op elsewhere; both runtimes above have been used on this
repository's hosts (rootless podman on SELinux). The package has a
remote dependency (ZIPFoundation, exact-pinned in `Package.swift`), so
the first build or `swift package resolve` inside the container needs
network access and `git` (the resolute image ships it); it fetches into
the scratch tree and commits nothing beyond the checked-in
`Package.resolved`.

CI enforces macOS/Linux toolchain parity with
`scripts/check-toolchain-parity.sh`, which every Swift-building job runs
against a full checkout. It compares full marketing versions read from
`swift --version` against the container pin in
`.github/workflows/ci.yml`, treating a missing patch component as `.0`
(Apple prints "6.4" where the pin says "6.4.0"). An Xcode point release
that changes the Swift patch version — 6.4 -> 6.4.2 — therefore fails
every macOS job until the container image is bumped to match; that
strictness is deliberate.

`--scratch-path .build-linux` keeps the Linux build tree out of `.build`
so container runs and host macOS builds do not invalidate each other's
caches (alternating them would otherwise force a full rebuild each time).
Platform-API assumptions that look correct on macOS
(`String(localized:defaultValue:)`, Mach VM probes) do not exist on
corelibs-foundation; the container catches them before they burn a CI
cycle.

Benchmark scripts need release-mode test builds; the CI "macOS (release-compile)" matrix leg (via the reusable macos-verify.yml workflow) guards them.

GUI changes additionally require the relevant honest manual check in
[docs/manual-testing.md](docs/manual-testing.md).

## Detailed References

- [README.md](README.md) — product overview and local build entrypoint
- [docs/architecture.md](docs/architecture.md) — data flow and abstractions
- [docs/import-formats.md](docs/import-formats.md) — supported formats and limits
- [docs/training-load.md](docs/training-load.md) — training-load model, defaults, estimator, and limits
- [docs/manual-testing.md](docs/manual-testing.md) — GUI and release checks
- [docs/private-data.md](docs/private-data.md) — private-data hygiene
- [docs/phase-plan.md](docs/phase-plan.md) — planning context, not executable truth
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — enforced CI behavior

## FIT Reference Implementations

When a question about the FIT protocol needs settling — field layouts, base
types, enums, scale/offset semantics — derive the answer from the official
Garmin SDKs whose bindings this codebase resembles, in this order of
authority, and quote the specific file and line:

1. <https://github.com/garmin/fit-cpp-sdk> — official C++ SDK, closest to
   `RunPlayEngineCpp`.
2. <https://github.com/garmin/fit-c-sdk> — official C SDK.
3. <https://github.com/garmin/fit-swift-sdk> — official Swift SDK, closest to
   `RunPlayCore`'s decoding.

Their generated `Profile` sources are the authority for message field
layouts and enums — not a third-party port and not a trimmed table copied
from another binding.

Do **not** settle FIT questions from the Python or Java bindings. Whether a
binding applies scale/offset to developer fields is that binding's own
choice, not the protocol's, and those two diverge from the SDKs above on
exactly that point. They may be cited as corroboration, never as authority.

If the C++ and Swift SDKs disagree, report the disagreement and the code that
shows it rather than silently picking one; record which this repo follows and
why, and make the contested case observable at runtime. Worked example:
`FITDeveloperFieldResolver.physicalValue(of:description:)` and the
developer-data section of [docs/import-formats.md](docs/import-formats.md).
