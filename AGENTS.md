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
4. Tool entrypoints such as `CLAUDE.md` and `GEMINI.md` import this file and
   must not duplicate or override policy.

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
  CI workflows, `AppState`, and shared architecture documents.
- Do not overwrite unexplained changes or resurrect commits removed by a history
  cleanup.
- After rebasing onto updated `main`, rerun the relevant verification suite.

## Architecture Boundaries

Dependency direction is:

```text
RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngine
```

Reverse dependencies are forbidden. `RunPlayPlatform` and `RunPlayStudio` must
not import `RunPlayEngine` directly.

- **RunPlayEngine** is the pure Swift computational engine. It uses only the
  Swift standard library and the platform C math module (no Foundation, I/O,
  Apple frameworks, third-party dependencies, retained closures, or
  callbacks), builds with strict memory safety, and is a non-product target
  that only `RunPlayCore` imports, with `internal import`, through the
  adapters in `RunPlayCore/Sources/Engine`. The package contains no C or C++
  target and enables no C++ interoperability. The engine provides the route
  input value and its sample ceiling, scalar geodesy primitives (coordinate
  validation, Haversine distance, local-metre projection), and one kernel per
  production operation:

  - combined route-quality geometry (`EngineRouteQuality`): outlier evidence,
    isolated-point rejection, implicit gap inference, final segment
    compaction, the supplied-distance policy, and normalized cumulative
    distances, in one engine call per route. Swift Core owns stage-1
    validation and the source-speed checks.
  - per-workout personal heatmap coverage (`PersonalHeatmapCoverage`): Web
    Mercator projection, grid-cell quantization, effective-segment gap
    breaking, supercover interval traversal, per-workout cell de-duplication,
    and deterministic cell ordering, in one engine call per workout per
    adaptive attempt. The engine returns exactly the cells it found. Core
    owns date filtering, the adaptive resolution loop, cross-workout
    aggregation, the minimum-workout-count filter, and snapshot finalization;
    it increments the cross-workout dictionary directly from the returned
    cells. The dictionary uses bounded reservation hints, not a product
    limit, and `PersonalHeatmapCellID` equality and `Codable` identity remain
    the original X/Y pair.
  - the constrained-DTW path solve for Route-Aware comparison
    (`RouteAlignmentDtw`): band radius, packed row layout, band-cell budget
    validation, geometry-only point cost, open prefix/suffix seeding,
    constrained transitions with fixed tie priority, consecutive-warp
    capping, endpoint selection, and path reconstruction, in one engine call
    per alignment attempt.
  - the segment and personal-record window searches (`SegmentDetection`):
    fastest 400m, fastest/slowest 1km, biggest climb/descent, and the five
    fixed-distance personal-record windows (fastest 1 mile, 5 km, 10 km, half
    marathon, marathon), in one engine call per `SegmentDetector` invocation.
    Core owns policy calculation, public `SegmentHighlight` and
    `PersonalRecordWindow` construction, UUIDs, titles, subtitles, final
    range metadata, HR averages, cancellation, diagnostics, and persistence.
  - the multi-pass `ElevationProfile` build (`EngineElevationProfile`):
    source altitude screening, endpoint and isolated spike rejection,
    short-excursion rejection, supported rejected-sample interpolation,
    continuous altitude-run identification, reliable-run classification,
    distance-domain smoothing, cumulative corrected signed change,
    reliable-interval counting, and deadband-confirmed cumulative
    ascent/descent, in one engine call per profile build. Core owns
    route-point UUIDs, each point's source altitude (DEM or recorded) and the
    continuity break at a switch between them, the public
    `ElevationProfile`/`ElevationProfileSample` models, all distance-query
    APIs, policy ownership, cancellation, diagnostics, and persistence.
  - pace, heart-rate and power route-metric scale and bucket finalization
    (`RouteMetricScaleBuckets`): deterministic distance-weighted
    lower/median/upper scale construction, numeric normalization, bucket
    assignment, and numeric summary construction, in one engine call per
    profile finalization. Equal sort keys keep source order, so an
    equal-weight `+0`/`-0` metric tie has one result on every platform.
    Corrected-elevation scale/bucket finalization intentionally stays in
    Swift Core: a production A/B showed an engine regression above the hard
    gate; that is mode-owned ownership, not an error-driven fallback. Core
    owns raw pace, heart-rate, and corrected-elevation extraction,
    distance-domain smoothing, scale direction, localized labels, public
    route-metric models, availability and caching, Platform line coalescing,
    cancellation, diagnostics, UI state, and persistence.
  - heart-rate training load (`TrainingLoadKernel`): interval-weighted
    Banister TRIMP accumulation and five-zone time bucketing, in one engine
    call per training-load pass over a Core-built array of same-segment
    heart-rate intervals. Core owns interval construction from route points
    (active-time weights that never span a recording gap or pause), the
    athlete-profile policy (resting/max heart rate, coefficient set, zone
    bounds), the measured-versus-estimated decision, the pace/duration
    estimator, public models, cancellation, and persistence.
  - DEM tile planning and bilinear sampling (`DemTilePlanning`,
    `DemElevationSampling`): the planner lists the exact set of XYZ Web
    Mercator tiles that bilinear samples of a route read — neighbours within
    half a pixel of a tile edge and across the antimeridian included,
    coordinates beyond the projection limit needing none — and the sampler
    bilinearly samples Core-decoded tile heights at every coordinate,
    returning a per-point status (sampled, invalid coordinate, outside
    projection, missing tile, implausible height), in one engine call each
    per correction pass. Both calls share one footprint rule, so sampling
    never reads a tile planning did not list. Core and Platform own tile
    discovery, file reading and image decoding, the tile budget, elevation
    precedence, public models, cancellation, and persistence; no engine
    source performs file I/O.

  No scalar per-point engine calls are allowed in production: every
  production operation above is one engine call, and
  `EngineCallCardinalityTests` enforces it.
- **RunPlayCore** is the stable Swift-facing core facade: domain models,
  `Codable` compatibility, Swift errors/diagnostics, actors and concurrency
  adaptation, filesystem persistence, schema migration, and translation
  between Core models and engine values. Engine types must not appear in
  public `RunPlayCore` APIs. Core remains cross-platform Foundation
  logic with conditional `FoundationXML`; it must not import UI, map,
  graphics, Core Location, or Combine. Core owns route-size
  validation, basic field sanitization, sorting, initial source-segment
  compaction, source-speed validation, diagnostics translation,
  public models, and persistence. For Route-Aware comparison, Core
  builds the compact alignment samples (at most 2,000 per route), detects
  route direction, constructs alignment blocks from the returned index path,
  calculates diagnostics and quality, maintains the in-memory cache and task
  lifecycle, and publishes the public alignment models. Use `GeoDistance` for
  Core geodesy stages, not `CLLocation`.
- **RunPlayPlatform** contains macOS non-SwiftUI adapters for SceneKit, AppKit,
  MapKit, ImageIO (DEM tile decoding), and non-UI Combine. It must not depend
  on `RunPlayStudio`.
- **RunPlayStudio** owns SwiftUI, Charts, app lifecycle, GUI state, and UI
  export.

See [docs/architecture.md](docs/architecture.md), [docs/engine.md](docs/engine.md)
and [Package.swift](Package.swift) for the live architecture and package graph.

### Swift engine policy (defaults)

Allowed and encouraged in `RunPlayEngine`: value semantics, `package` access,
borrowed `Span` inputs, `[T]` outputs built with
`Array(unsafeUninitializedCapacity:)` or `InlineArray`, `MutableSpan` over a
caller-visible output as the working buffer, typed `throws` with one error
enum per kernel, `@inline(__always)` on measured hot helpers, and standard
library algorithms.

Requires explicit justification: an `unsafe` expression (strict memory safety
makes each one visible; keep it to buffer initialization and measured
unchecked span access, each with a `SAFETY:` comment that says why it is
sound), classes or reference semantics, `@unchecked Sendable`, mutable global
state, generics on a hot path, a `fatalError`/`precondition` that input data
can reach.

Forbidden: imports other than the Swift standard library and the platform C
math module, Foundation, I/O, retained closures, callbacks into Core,
per-element engine calls from Core, engine types in a public `RunPlayCore`
signature, engine imports outside `RunPlayCore`, and test-only code in
`RunPlayCore/Sources`.

Every kernel boundary follows one contract:

- Core owns every input. The engine borrows it as a `Span` for the duration
  of one synchronous call, retains nothing, and performs no callback.
- The engine returns its output by value: an array holding exactly the
  entries it produced, or a summary struct. A per-sample kernel returns one
  entry per input sample. No kernel negotiates capacity or asks for a retry.
- A failed call throws the kernel's typed error and returns nothing, so no
  partial output exists.
- One engine call occurs per production operation; none occurs per sample,
  row, cell, window, tile, or interval.
- Cancellation is cooperative Core work, checked before and after the engine
  call and during conversion and output translation, never inside the call.

Kernel-specific bounds:

- Constrained DTW: alignment sample count is bounded in Core
  (`RouteAlignmentPolicy.maximumSamplesPerRoute`, 2,000 per route) and the
  solve is bounded by `maximumBandCells` (4,000,000), checked both as an
  estimate before allocation and exactly after the packed row layout is
  built. A valid path never exceeds
  `primary_sample_count + comparison_sample_count + 1` cells.
- Segment detection returns at most ten candidates: the five
  segment-highlight kinds plus one candidate per personal-record window that
  the route actually covers. The eight internal searches (fastest 400m,
  combined one-kilometre pace, five personal-record windows, and combined
  elevation) each keep their per-search evaluation bound.
- Elevation profile: the output array is the route-sized workspace; the build
  makes no other route-sized allocation.
- Training load is summary-only: every product of the pass (Banister TRIMP,
  five-zone seconds, valid and covered time, interval counts) returns in one
  summary value.
- DEM tile planning returns the tiles strictly ascending by (y, x). It is
  bounded by the tile budget Core passes: a route needing more tiles throws
  the budget error, which Core treats as "keep recorded elevation for this
  workout", not as a retry signal.
- DEM sampling takes the tiles present as a directory, strictly ascending by
  (y, x) and within the tile budget, with exactly `tile_count * tile_size^2`
  single-precision heights in directory order; the engine validates that
  whole contract before it produces any output. A tile absent from the
  directory is not an error: each affected coordinate reports the
  missing-tile status and falls back on its own. The engine never reads a
  file, decodes an image, or calls back for a tile.

Supported workout size is bounded in Core, never at the engine boundary.
`WorkoutImportResourceLimits` defines the product limits once — 1,000,000 route
points per resulting workout and a 100 MB source payload — and every importer
plus the `RouteQualityProcessor` preflight reads them from there. The engine's
`EngineRouteLimits.maxRouteInputSamples` is an internal safety ceiling 25%
above the product limit, so a route the app accepts can never be rejected by
the engine. Raising the product limit requires raising that ceiling to
preserve the margin; a parity test enforces the relationship. Do not add a
second copy of either number to an importer.

Engine numerical code is a literal translation of the C++23 kernels it
replaced, and stays one until a change of behaviour is explicitly decided.
Preserve constants, operation order, and existing limitations, and keep each
multiply and add in its own statement where the original did, so every
intermediate is rounded exactly as before. The one decided difference is the
`+0`/`-0` scale-bucket tie above. Each kernel's golden digest test
(`*GoldenTests.swift`, one FNV-1a-64 digest per CI platform, derived from the
C++ kernel before its removal) pins the outputs bit for bit: a change that
moves a digest is a behaviour change and needs that decision.

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

## Lane selection

A pull request runs only the lanes and test targets its changed paths can
reach. `scripts/ci-select-lanes.sh` holds the table; the `changes` job in
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs it, and `lint`
self-tests it on every PR. The module graph is
`RunPlayEngine` → `RunPlayCore` → `RunPlayPlatform` → `RunPlayStudio`, and
each change reaches its own module and the modules downstream.

| Changed path | Runs |
|---|---|
| `*.md` outside `RunPlay*/**` and `Tests/**`, `docs/**` (including `docs/assets/**`), `prompts/**`, `LICENSE` | lint only |
| `RunPlayStudio/**` (a `*.md` there too) | macOS, Studio tests, boundary validator |
| `RunPlayPlatform/**` | macOS, Platform and Studio tests, boundary validator |
| `RunPlayCore/**`, `RunPlayEngine/**`, `Tests/**`, `Package.swift`, `Package.resolved`, `scripts/**`, `script/**`, `.github/**`, `Packaging/**`, `VERSION`, and any path not listed | everything |

- Every path is classified and the widest result wins; a renamed file counts
  under both its old and new path.
- The selector fails open: an unlisted path, an empty or unreadable diff, or
  any event other than `pull_request` selects everything. The nightly reaches
  `ci.yml` through `workflow_call`, so it always runs everything on `main`;
  a wrong mapping therefore shows up on the next nightly.
- On a stacked PR the diff is against the parent PR's branch, so a child PR's
  selection covers only its own changes. Each PR below it is verified by its
  own CI.
- The engine boundary validator
  (`scripts/validate-swift-engine-boundaries.py`, a static source scan plus a
  check of the SwiftPM target graph) runs once per CI run, in the tests leg
  of `core-linux`, which therefore runs when the selector turns on `linux` OR
  `macos`: the validator scans Core, Platform and Studio, so a Studio-only PR
  needs it. When only `macos` is on, that leg runs just the checkout and the
  validator, and the sanitizers leg skips all its steps; the engine tests,
  the Core gate, consumer smoke and the AddressSanitizer run need `linux`.
  Every macOS job runs the validator's target-graph check (`--graph-only`),
  because the Linux package graph omits the macOS-only Platform and Studio
  targets; the release path runs the whole validator through
  `macos-verify.yml`'s `boundaries` input. The Swift image pin stays on the
  one `container:` line in `core-linux`.
- Every macOS run also checks the String Catalogs
  (`scripts/check-localization.sh`) without a second build: the one
  `swift build --build-tests` passes `-emit-localized-strings`, which only adds
  `.stringsdata` outputs, and the check reads that extraction with
  `--skip-build --scratch-path .build --stringsdata-dir <dir>`. The release path
  runs it too, and a macOS-only change to a module's strings or catalog selects
  the macOS lane through `RunPlay*/**`.
- The `CI` gate accepts a skipped lane only when the selector turned that
  lane off (`core-linux`: both `linux` and `macos` off); a lane the selector
  turned on must succeed.
- Adding a module, or a test that reads a file outside its own module (for
  example by `#filePath`), means updating `scripts/ci-select-lanes.sh` in the
  same PR. Tests that read the repository (`RunPlayStudio/Resources/**`
  fixtures) are covered by the table above.

## Validation

Use the same warning-clean SwiftPM commands enforced by CI. Warnings are
errors in every Swift target we own: `Package.swift` sets `.treatAllWarnings(as:
.error)` on them (and on `Tests/PackageConsumerSmoke`'s target), so a plain
`swift build` or `swift test` is the gate on macOS and Linux. Do not pass `-Xswiftc -warnings-as-errors`: it also
reaches dependency targets, which SwiftPM compiles with `-suppress-warnings`,
and swift-build on Swift 6.3 rejects that combination.

```bash
python3 scripts/validate-swift-engine-boundaries.py
swift build --target RunPlayEngine
swift test --filter RunPlayEngineTests
LSAN_OPTIONS=suppressions=$PWD/scripts/lsan-xctest-discovery.supp \
  swift test --sanitize=address --filter RunPlayEngineTests   # engine tests under ASan (Linux)
swift test --filter RunPlayCoreTests
swift build --package-path Tests/PackageConsumerSmoke
swift test --filter RunPlayPlatformTests                               # macOS
swift test                                                            # macOS full stack
./scripts/check-localization.sh   # macOS: catalogs match source; zh-Hans/zh-Hant complete
git diff --check
```

**Swift 6.3.x on macOS needs `--build-system swiftbuild`.** SwiftPM 6.3's
default (native) build system copies a String Catalog uncompiled: the resource
bundles get no `.lproj` folders and no plural forms, and the localization tests
fail. The swift-build system compiles the catalogs and is the default from
Swift 6.4. CI (`macos-verify.yml`) and the scripts that build the app
(`assemble-app-bundle.sh`, `test-release-packaging.sh`,
`generate-demo-assets.sh`, `check-localization.sh`, `script/build_and_run.sh`)
pass the flag, and a `swift test --skip-build` must use the build system that
built. On Linux the native system stays: it builds Core without catalogs (the
Core catalog is declared on macOS only), and swift-build's libdispatch crash on
Linux is what `retry-swiftpm-libdispatch-crash.sh` handles.

A filtered or soaked run must assert the expected `Executed N tests` count
for the named suite, never just the exit code. `swift test --filter` exits 0
when the filter matches nothing, so a loop that branches on the exit status
reports a clean 25/25 having run nothing. Anchor the check on the suite's own
summary line: `swift test` runs every bundle, and the ones with no match print
`Executed 0 tests`, so the first `Executed` line in the log is usually an
unrelated zero.

A run must also report how many tests actually executed, not just that nothing
failed. XCTest counts **skipped tests inside** `Executed N tests`: five test
methods with three skipped report `Executed 5 tests, with 3 tests skipped`, so
`N - S` is the number that genuinely ran. `0 failures` alone cannot distinguish
a full suite from a suite where nearly everything took an `XCTSkip` path, which
is exactly the shape a corelibs-only breakage takes — `canImport(FoundationXML)`
is true on Linux, so a mass skip would have to come from a test-side guard, and
this gate could not see it. Report `Executed N, skipped S, ran N-S`. Report the
same figures when citing a Linux result in a PR: a bare test count is not
evidence that those tests ran.

The Linux gate then keys on **skip reasons, not counts**. A count ceiling was
the first design and was rejected: it cannot catch mass-skipping (90 skips sits
under any bound loose enough to survive ordinary drift that way) and it rots as
Core grows. Instead every skip reason in the run must match an allowlist in
`scripts/linux-container-verify.sh` (`ALLOWED_SKIP_PATTERN`): the `RUNPLAY_*=1`
benchmark/profile switches, and nothing else. A reason outside that set fails
the gate **and names the reason**, so a mass skip cannot pass and the gap that
tripped it is reported rather than a bare number moving. The root-only
`testFailedWorkoutWritePreservesPriorValidData` skip ("root bypasses POSIX
permission bits") is deliberately absent: every entrypoint runs non-root, so
that reason appearing means one regressed to root and lost the
permission-injection coverage. The gate reads both shapes corelibs XCTest
prints (`Test skipped: required … - <msg>` from `XCTSkipIf`/`XCTSkipUnless`,
`Test skipped - <msg>` from a bare `throw XCTSkip`) and fails unless it parsed
exactly one reason per skip XCTest counted, so a skip it cannot read fails
rather than bypassing the allowlist.

CI runs this same script — the Linux `tests` leg calls
`./scripts/linux-container-verify.sh native` rather than a bare `swift test`,
so the allowlist and floor gate merges, not just local runs. `native` runs
`swift test` directly because the job is already inside the pinned image, and
refuses uid 0. The job's container starts as root (its `apt-get` step needs
it), so the step hands the checkout to an unprivileged uid, drops to it with
`setpriv`, and hands the tree back afterwards.

A **floor** (`RUNPLAY_LINUX_MIN_EXECUTED`, 1,378) guards the count that
actually ran. It is not redundant with the allowlist: the allowlist sees only
tests that *print* a skip, while a test class compiled out on Linux
(`#if os(macOS)`, a `canImport` guard that is false on corelibs) or dropped from
the target vanishes without a line, so the count is the only guard against
silent disappearance, and it is tight enough to bite. Provenance: 1,378 against
1,450 executed on the head that set it, under the non-root container user
(`Executed 1470, skipped 20`), about 5% headroom. That head lowered the floor
from 1,389 on purpose: it removed the C++ engine and, with it, the 14 XCTest
cases that tested only the C++ bridges. The headroom is room for a PR that
legitimately deletes a few tests, not tolerance for drift. A PR removing more
lowers the floor deliberately and says why. Raise it back to ~5% below the real
count in the PR that adds Core tests once the headroom passes ~10%.

The parser is itself tested: `./scripts/linux-container-verify.sh --self-test`
runs `gate_log` over fixtures in `scripts/fixtures/linux-container-verify/`
(two real CI logs from the negative control, plus one synthetic log per failure
path) and asserts each verdict. Every gate run self-tests first on the image's
`mawk`, and the macOS verification job runs it on BSD awk. A parser change that
breaks a verdict fails there, not on a merge. A new skip shape or failure path
gets a fixture in the same change.

**A failure means investigate, never bump.** A *drop* in executed tests or a
*rise* in skips is a signal that something changed on the test side; find out
what and why first. Raising the floor or adding a reason to the allowlist is a
deliberate act that belongs in the PR introducing the newly-skipping tests, with
the reason stated there — not in a drive-by edit that restores the original
problem.

CI and a local run measure the same thing: both run non-root, so on one
commit their `Executed N, skipped S` figures should match. Run as root, the
same suite reports one more skip (measured in the pinned image: 17 skipped as
root against 16 non-root, out of 1,096), and the gate now fails that by name.

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
builds — and the manifest's `treatAllWarnings(as: .error)` cannot catch it
because it is a dependency-manifest diagnostic, not target compilation. It is
upstream's to fix; do not re-investigate.

One crash is known and retried: on Linux, SwiftPM 6.4 itself can die
of SIGSEGV (exit 139) in libdispatch's `_dispatch_event_loop_drain`
while swift-build pre-plans a build — an upstream epoll use-after-free
(swiftlang/swift#87033, swiftlang/swift-corelibs-libdispatch#949), not a
package bug. Every SwiftPM build in the Linux CI lane, including the
`swift test` inside `scripts/linux-container-verify.sh`, runs through
`scripts/retry-swiftpm-libdispatch-crash.sh`. It reruns a command once
for exactly that crash signature, and only while SwiftPM has reported no
error and not yet printed `Build complete!`, so a reported build error
or any test result is final; `-q`/`--quiet` and `--skip-build` hide that
line, so they turn the retry off. Each retry leaves a warning annotation
on the run. Do not widen the wrapper to other failures; delete it once
the pinned image ships the libdispatch fix.

Isolated verification runs: SwiftPM has no `--manifest-cache-path`
(observed on 6.3.3: `swift build`, `swift test` and `swift package`, with
or without a subcommand, reject it as an unknown option) and keeps the
manifest cache under `--cache-path`, so redirecting `--cache-path` covers
both. On 6.3.3 `--scratch-path` and `--cache-path` are accepted both
before and after the `package` subcommand (`show-dependencies`,
`resolve`) and as direct options of `swift build` and `swift test`.
Use `swift package --scratch-path X --cache-path Y <subcommand>`.

RunPlayCore changes must verify the Linux build in a container before
pushing. Linux CI is Docker-only by policy: the CI job runs inside the
official Swift image pinned by the single `container:` line in
[.github/workflows/ci.yml](.github/workflows/ci.yml), and local
verification must use that exact image, read from the same pin so the
two cannot drift (currently `swift:6.3.3@sha256:4f4230…29b1e9`). The invocation is single-sourced in
[scripts/linux-container-verify.sh](scripts/linux-container-verify.sh),
which reads the pin by its `container:` key (the shape-documenting
comment above the line matches a plain `swift:` grep — the same reason
the CI identity step anchors on the key) and fails fast
if the line moves:

```bash
./scripts/linux-container-verify.sh                                # full RunPlayCoreTests
./scripts/linux-container-verify.sh --filter RouteGroupingTests     # a narrower filter
./scripts/linux-container-verify.sh podman ...                      # force the runtime
./scripts/linux-container-verify.sh native                         # already inside the image, non-root (CI)
```

Without a forced runtime the script probes the candidates rather than
trusting their names: a `docker` binary that reports podman (Fedora's
`podman-docker` shim) is driven with podman's flags, because the docker
branch omits `--userns=keep-id` and the shim is rootless podman. The
script always runs `swift test` warning-clean with the scratch tree at
`.build-linux`, and preserves two mandatory properties:

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

Runtime specifics the script applies: the volume is mounted `:Z`
(relabels for SELinux-enforcing hosts, a no-op elsewhere), and rootless
podman runs with `--userns=keep-id` — without it the container uid maps
into the subuid range, `/src` appears root-owned, and the non-root user
cannot write the checkout (the failure surfaces as SwiftPM `invalid
access to /src/.build-linux/repositories`); `--userns=keep-id` is
podman-specific and rejected by docker, which is why the runtimes
differ. The package has a remote dependency (ZIPFoundation, exact-pinned
in `Package.swift`), so the first build or `swift package resolve`
inside the container needs network access and `git` (the pinned image
ships it); it fetches into the scratch tree and commits nothing beyond
the checked-in `Package.resolved`. That checkout is also why the script
passes `safe.directory` as container-scoped `GIT_CONFIG_*` environment
entries: a Docker Desktop bind mount on macOS does not satisfy git's
ownership check even when `-u` matches the host uid, and the run dies
with `detected dubious ownership in repository at
'/src/.build-linux/checkouts/ZIPFoundation'`. The exception must name
the checkout, not the mount — `safe.directory` is an exact-path match,
so a lone `/src` fails identically — hence `/src` plus git's recursive
`/src/*`. Passing it through the environment changes nothing on the host
or in the repository, and it is inert wherever the uid already owns the
mount, which is why Linux CI and rootless podman never needed it.

The Swift version in the Linux image must equal the Swift in the Xcode that
`setup-macos-build` provides to the macOS jobs, so both platforms test one
toolchain. This is a convention, not a CI check: bump the `container:` pin in
[.github/workflows/ci.yml](.github/workflows/ci.yml) and that Xcode in the
same PR. An Xcode point release that changes the Swift patch version needs a
matching image.

`--scratch-path .build-linux` keeps the Linux build tree out of `.build`
so container runs and host macOS builds do not invalidate each other's
caches (alternating them would otherwise force a full rebuild each time).
Platform-API assumptions that look correct on macOS
(`String(localized:defaultValue:)`, Mach VM probes) do not exist on
corelibs-foundation; the container catches them before they burn a CI
cycle.

Benchmark scripts need release-mode test builds; the nightly workflow (nightly.yml, via the reusable macos-verify.yml workflow) guards them with a release-mode test compile, not the PR lane. Release packaging is not in CI or the nightly: `release.yml` verifies it, and a dry run of it (`dry_run=true`) on the tag commit is the pre-tag check ([docs/releasing.md](docs/releasing.md)).

GUI changes additionally require the relevant honest manual check in
[docs/manual-testing.md](docs/manual-testing.md).

A change that alters the PNG summary card should refresh the committed README
cards in the same PR, as [docs/demo-assets.md](docs/demo-assets.md) describes:
run `./scripts/generate-demo-assets.sh` or the manual Demo Assets workflow and
commit the curated files. CI does not compare or enforce them. The cards are
binary, so serialize PRs that change the card.

## Detailed References

- [README.md](README.md) — product overview and local build entrypoint
- [docs/architecture.md](docs/architecture.md) — data flow and abstractions
- [docs/engine.md](docs/engine.md) — engine kernels, boundaries, and verification
- [docs/import-formats.md](docs/import-formats.md) — supported formats and limits
- [docs/training-load.md](docs/training-load.md) — training-load model, defaults, estimator, and limits
- [docs/dem-tiles.md](docs/dem-tiles.md) — DEM tile folders, elevation precedence, and limits
- [docs/localization.md](docs/localization.md) — String Catalogs, localised formats and exports, catalog check
- [docs/manual-testing.md](docs/manual-testing.md) — GUI and release checks
- [docs/demo-assets.md](docs/demo-assets.md) — README demo media generation and size budget
- [docs/private-data.md](docs/private-data.md) — private-data hygiene
- [docs/phase-plan.md](docs/phase-plan.md) — planning context, not executable truth
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — enforced CI behavior

## FIT Reference Implementations

When a question about the FIT protocol needs settling — field layouts, base
types, enums, scale/offset semantics — derive the answer from the official
Garmin SDKs whose bindings this codebase resembles, in this order of
authority, and quote the specific file and line:

1. <https://github.com/garmin/fit-cpp-sdk> — official C++ SDK, the reference
   implementation.
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
