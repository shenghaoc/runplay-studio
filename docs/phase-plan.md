# RunPlay Studio — Phase Plan

## Completed Phases

### Foundation ✅
- SwiftPM three-layer architecture (RunPlayCore / RunPlayPlatform / RunPlayStudio)
- Data models: RunWorkout, RoutePoint, RunSplit, RunSummary, SegmentHighlight, ReplayState, RouteScenePoint
- JSON importer, WorkoutAnalyzer, SplitCalculator, SegmentDetector, MetricSmoother
- GeoDistance (Haversine), RoutePointInterpolator, RouteProjectionService
- ReplayController with playback state, seek, and speed control
- SwiftUI shell: ContentView, SidebarView, WorkoutDetailView, OverviewView
- Swift Charts: pace, elevation, HR, speed with chart click-to-seek
- Split table and run summary views
- Unit test suite (RunPlayCoreTests, RunPlayPlatformTests, RunPlayStudioTests)

### GPX Import ✅
- GPX track segment parsing with per-segment route indexes
- HR and cadence via GPX extensions
- Partial timestamp interpolation
- Multi-segment gap-safe analytics and rendering

### TCX Import ✅
- TCX laps and tracks with per-track route indexes
- HR, cadence, distance parsing
- Ambiguous multi-GPS-activity rejection
- Partial timestamp interpolation

### FIT Import ✅
- CRC-validated binary parser (header and file CRC)
- Compressed timestamp decoding
- Session selection (one unambiguous GPS-bearing running session)
- Timer pause/resume boundaries → route segment indexes
- Enhanced altitude/speed, supplied distance rebasing per segment
- Resource limits and cancellation cooperative checks
- Real-device-file import landed in #143: before it, the header data-type
  check required `"FIT "` instead of `".FIT"` and rejected every genuine file,
  and a device writing `session.timestamp == start_time` (duration only in
  `total_elapsed_time`) collapsed a whole run to a single route point. Degenerate
  lap end timestamps derive from `start_time + total_elapsed_time` the same way.

### Synchronized Replay ✅
- Unified ReplayController as single source of truth
- Map marker, chart indicator, metrics panel, split highlight all sync to timeline
- Chart click/drag-to-seek pauses playback and seeks position

### Segment Detection ✅
- Fastest 400m, fastest 1km, slowest 1km, biggest climb, biggest descent
- Distance-based sliding windows (uneven GPS sampling safe)
- Segment highlights panel with seek-on-select

### Export ✅
- JSON summary, splits CSV, segments CSV, combined CSV, PNG summary card (exact 1200×1600 pixels)
- All exports local via NSSavePanel
- Configurable PNG export: optional Apple Maps region, Light/Dark appearance, route-color modes
- Deterministic `ImageRenderer` rasterization at scale 1.0 (no `NSScreen` dependence)
- MapKit snapshot + manual route overlay composition; metrics-only fallback

### Route Comparison ✅
- Distance-aligned comparison (no dynamic time warping)
- Summary metric deltas, split active-pace table, active-pace-over-distance chart
- Shared `RouteMapCanvas` for comparison overlay
- Distance slider with P/C markers plus explicit elapsed-time, active-time, and active-pace delta readout
- Warnings: different distances, pause-duration mismatch, insufficient overlap, missing HR/elevation

### Unified Apple Maps 2D/3D Presentation ✅
- Single SwiftUI `Map` surface replacing legacy SceneKit prototype
- One in-map 2D/3D camera pitch toggle (0° vs pitched `MapCamera`)
- Realistic-elevation map style in both modes
- Shared `RouteMapCanvas` for single-run and comparison maps
- Route polyline, replay marker, start/finish annotations preserved in both modes

### Persistent Workout Library ✅
- `FileWorkoutLibraryStore` with atomic writes under Application Support
- Versioned `WorkoutLibraryManifest` with selection persistence
- `WorkoutLibraryStoreActor` serializing all mutations
- Background library load on startup; bundled demos shown only when library is empty
- Import/delete with transactional rollback on failure
- Library persists across app relaunches; original imported files untouched

### Scalable Workout Library (All Runs) ✅
- All Runs workspace with search, filters, sort, favourites, name/notes editing
- Manifest schema v2 favourites; bounded sidebar (Favourites / Recent / Selected Run)

### Tags and Smart Collections ✅
- User-defined tags (finite color palette) with bulk assignment; tags live in the manifest, not workout snapshots
- Tag search/filter (any/all/untagged) reuses `WorkoutLibraryQueryService`
- Smart collections are saved dynamic queries (search/filters/tags/sort); relative dates resolve on open
- Manifest schema v3; Modified/Revert/Update collection chrome; session-backed manual query restoration
- Bounded Smart Collections sidebar; Manage Tags / Manage Collections sheets
- In-memory search index; no route-point scanning during ordinary query
- Off-main cancellable query service; heatmap isolation preserved

### Native Window and Application Session Restoration ✅
- Stable-ID singleton `Window` with one app-owned `AppState` and native macOS frame restoration
- Separate bounded version-1 session JSON; manifest remains authoritative for library and selected-workout state
- Restores durable workspace, All Runs queries, smart-collection Modified state, heatmap filters, comparison, paused replay, tabs, map presentation, and sidebar visibility
- Validates missing/corrupt/future state and excludes transient sheets, alerts, operations, caches, result IDs, and active playback
- Actor-backed atomic writes with structural debounce, replay throttling, pause/lifecycle flushes, and synthetic focused tests

### Optional Watch-Folder Import ✅
- User-chosen directories auto-import new GPX/TCX/FIT/JSON files; opt-in, never on by default
- Security-scoped bookmark persistence (`watch-folders.json` beside the manifest) with stale-tolerant re-resolution; works identically once App Sandbox lands (enablement itself is a follow-up)
- Detection: authoritative ~5 s poll plus DispatchSource directory events as an early wake (missed events degrade to poll latency)
- Two-probe size+mtime settle (default 2 s) so files still being written are never imported; "Import Existing Files Now" bypasses settling for pre-existing files
- Per-folder SHA-256 content ledger: every outcome (imported/skipped/failed) is ledgered so nothing retries forever; identity is content, not filename (renames dedupe)
- Steady-state duplicates are silent; a skip row appears only for a renamed/copied duplicate
- Reuses the single-file import pipeline end-to-end (training-load restamp, store add, library refresh, per-folder default tag via existing tag APIs)
- Multi-session FIT files queue for the existing review sheet behind a non-modal banner; not ledgered until resolved
- Results surface in a toolbar popover "Recent Imports" panel (success/skip/error per file, reveal-in-Finder) and a Settings pane; no alert spam, no window blocking
- Unavailability is a first-class state, never silence: an ejected volume or removed folder is reported once per transition, marked **Unavailable** in settings, and resumes watching automatically when the directory returns
- Queued FIT reviews persist, so the banner survives relaunch and removing one folder re-surfaces another folder's queued review instead of stranding it
- VoiceOver is the only non-visual signal for a background import, so outcomes are announced once per scan pass (failure outranks success), never per file and never on an idle poll
- Parse-level import failure wording is shared with the manual path through one helper so the two cannot drift; only the two context-dependent cases are worded per caller
- Watch Folders… File-menu item opens the Settings pane (registered command, no additional shortcut)

---

## Active / Upcoming Phases

### Phase: HealthKit Research (Future)
- [ ] Research macOS HealthKit entitlements and availability
- [ ] Design import flow and privacy model
- [ ] Implement HealthKit workout query and importer

### Phase: Advanced Export
- [x] Dark mode PNG summary card variant
- [x] Map region screenshot in PNG export
- [x] Video export (AVFoundation) — offline deterministic H.264 MP4 route replay
- [x] Comparison replay video export — Distance and Route-Aware two-workout MP4

### Phase: Polish and Accessibility
- [x] Keyboard shortcuts for replay and navigation
- [x] Accessibility labels and VoiceOver support audit
- [x] Window state persistence across relaunches

### Phase: Expanded Import
- [x] Strava export (.zip) importer
- [x] Multi-session FIT batch import
- [x] FIT developer data: field_description/developer_data_id decode, name-based recognition with provenance, running power + dynamics on route points, per-field metadata/statistics retention (no per-point series, 16-field cap)
- [x] Running power + dynamics surfaces: power chart, replay badge, split/segment means, Power map coloring (warm-yellow ramp), best 20-min power (segment-safe time window in Swift), dynamics detail panel, JSON/CSV export fields with explicit units
- [x] Optional watch-folder import: security-scoped folder bookmarks, poll + DispatchSource detection, size/mtime settle, per-folder SHA-256 content ledger, non-modal recent-imports panel and review banner, per-folder default tag
- [ ] iPhone companion exporter (future)

### Phase: Portable C++23 Engine Migration
- [x] `RunPlayEngineCpp` C++23 foundation, native tests, ASan/UBSan, boundary validation
- [x] `RouteInputSample` bulk route-value boundary with Swift/C++ field parity
- [x] C++23 geodesy primitives (coordinate validation, Haversine distance, local-metre projection) with Swift parity coverage
- [x] Migrate coordinate-derived route step distances into C++ behind one bulk call (first production cutover)
- [x] Migrate route-quality geometry into **one** combined C++ kernel: distance relationships, isolated coordinate-outlier evidence, implicit-gap inference, segment compaction, supplied-distance validity, per-segment distance-source selection, and cumulative normalized distances
- [x] Migrate per-workout personal heatmap route coverage into one bulk C++ kernel: Web Mercator projection, grid-cell quantization, effective-segment gap breaking, supercover traversal, per-workout de-duplication, and deterministic cell ordering
- [x] Migrate the Route-Aware **constrained DTW path kernel** into one bulk C++ call per alignment attempt: band radius, unmatched prefix/suffix expansion, packed row layout, band-cell budget validation, geometry-only point cost, open-beginning seeding, constrained transitions with fixed tie priority, warp-run capping, endpoint selection, and path reconstruction
- [x] Profile cross-workout heatmap aggregation and record the decision
- [x] Optimize cross-workout heatmap aggregation **in Swift**, adding no native aggregation boundary: reserve the global count dictionary per adaptive pass, reduce `PersonalHeatmapCellID` hashing cost, and stop materializing a per-workout cell array
- [x] **Profile remaining core computational hotspots** (`RemainingCoreHotspotProfile` + Platform map-line/Strava harness): production-equivalent Mode A/B decomposition, exact parity digests, 5% accounting gate, statistical release timings, GPX/TCX/FIT/Strava/multi-session FIT, and 1M-point product-limit probes. Evidence drives the roadmap below.
- [x] **Migrate SegmentDetector to C++23**: one bulk window-search call over route distance, timeline clocks, and optional elevation snapshots selects at most five candidates; Swift retains public highlight construction, metadata, cancellation, and persistence. The cutover preserves duplicate-distance ownership, first-winner ties, active-pace limits, reliable elevation gaps, and per-search work bounds, with native, bridge, and end-to-end oracle parity coverage.
- [x] **Migrate ElevationProfile to C++23**: one bulk multi-pass call performs source screening, spike/excursion rejection, supported fill, run classification, distance-domain smoothing, and deadband-confirmed cumulative ascent/descent; Swift retains public models, UUIDs, distance queries, policy, cancellation, and persistence. Exact oracle parity required; no schema or analysis-version change.
- [x] **Migrate pace and heart-rate route-metric scale/bucket work to C++23**: one allocation-free bulk call per pace/HR finalization performs deterministic distance-weighted lower/median/upper scale construction, numeric normalization, bucket assignment, coverage accumulation, and numeric summary construction via a typed caller-owned eligible workspace plus output buffer. Corrected elevation intentionally retains Swift numeric finalization after production A/B showed a native regression above the hard gate (mode-owned ownership, not a fallback). Swift retains raw extraction, smoothing, localized labels, public profiles, availability/caching, Platform line coalescing, cancellation, diagnostics, UI, and persistence. Exact parity is required; no schema, analysis-version, normalization-version, importer, or public API change. Compatibility corrections keep the full public Swift `Int` `bucketCount` domain (`std::int64_t`), positive-infinite valid coverage, individually positive-infinite weights as valid but not quantile-eligible, and a no-sort fast path when a scale is known to be impossible.
- [x] **Final portable-core cleanup** (mandatory endpoint): transitional step-distance boundary removed entirely, public C++ boundary inventory, raw-pointer exception review, dead Swift oracle/duplicate removal, benchmark inventory, sanitizer matrix, package-consumer smoke, architecture docs, future iOS portability review.
- [ ] **Legacy SceneKit projection remains low priority** unless it regains a shipped caller

**Rejected for C++ migration (remain Swift)** — see also `docs/architecture.md`:

- `MetricSmoother` alone: sub-ms / small absolute cost.
- Import parsers (JSON/GPX/TCX/FIT) as C++ kernels: XML/binary decode is Foundation-bound; end-to-end import is not dominated by a portable numeric core once normalization/analysis is separated. TCX XML parse+build is expensive in absolute terms but is not a good C++23 engine candidate.
- `RouteAlignmentSampleBuilder`: remaining alignment cost outside native DTW is small on ordinary pairs; DTW path is already native.
- `MovementProfile`: the refreshed one-million-point analysis profile measured about 17 ms (8.5% of `analyze`); ordinary routes remain sub-millisecond end to end, so a native migration is not justified ahead of route metrics or cleanup.
- `SplitCalculator`: modest absolute cost; benefits if timeline/movement stay shared in Swift.
- Combined full-analysis kernel as the *first* cutover: SegmentDetector alone already holds most of the analysis wall and is more reviewable as one phase.

**Remaining phase count (portable-core migration + cleanup only):**

| Bound | Count | Contents |
|---|---:|---|
| Minimum | 0 | — |
| Expected | 0 | — |
| Maximum reasonable | 0 | — |

The portable-core migration and its mandatory cleanup are complete.

Swift performs route-size validation, basic field sanitization, sorting,
initial source-segment compaction, source-speed validation,
diagnostics translation, public models, and persistence.

C++ performs production outlier evidence, isolated-point rejection, implicit
gap inference, final segment compaction, supplied-distance policy, and
normalized cumulative distances through one bulk call.

No scalar per-point Swift/C++ production calls are allowed. No persisted schema,
analysis version, UI, or importer behaviour changes in this cutover.

#### Route-Aware comparison ownership after the DTW cutover

C++ performs the bounded band-packed constrained-DTW path solve for Route-Aware
comparison.

Swift continues to build the compact alignment samples, detect route direction,
construct alignment blocks, calculate diagnostics and quality, maintain the
in-memory cache and task lifecycle, and publish the public alignment models.

Bounds are maximum 2,000 samples per route and maximum 4,000,000 band cells.
One call occurs per alignment attempt; no calls occur per dynamic-programming
cell or row. Both inputs and the path output are Swift-owned buffers; C++
retains no pointer and performs no callback, and on any failure status the
output buffer is left completely unchanged. Cancellation is checked before and
after the native call and during conversion and output translation, never
inside the native call. Alignment sample construction, aligned metrics, and the
remaining comparison logic have not migrated.

#### Why geometry stages migrated as one phase

Each crossing of the engine boundary pays a fixed conversion tax — building the
`RouteInputSample` batch and converting the result back — that does not scale
with how much work happens after conversion. On a 100,000-point fixture that
tax was roughly 0.9 ms of a bridge call. Migrating each geometric
stage separately would pay it repeatedly; migrating them together pays it once.

The combined kernel reuses internal pairwise step logic directly. Product limit
(1,000,000 points) and engine ceiling (1,250,000 samples) are unchanged.

`scripts/run-route-quality-benchmark.sh` compares complete Swift stages 2–4
against the complete combined bridge (including conversion).

#### Why cross-workout heatmap aggregation stays in Swift

`scripts/run-personal-heatmap-profile.sh` decomposes one production-equivalent
Personal Heatmap build into additive phases, retaining every adaptive pass and
splitting the coverage boundary into native execution, caller-owned output
allocation with capacity retries, and direct native-buffer cell
consumption/counting. Run it for current numbers; they are machine-specific and
are not recorded here.

The profile's durable conclusions are:

- The already-native per-workout coverage kernel dominates every
  production-reachable configuration.
- Cross-workout counting is the largest remaining Swift cost, and that cost is
  Swift `Hasher` work plus dictionary growth rather than algorithmic work.
- Output allocation, including every capacity retry, is too small to justify a
  new boundary.
- Sorting and cell materialization are bounded by the rendered-cell budget. The
  shipping UI always requests
  `PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount`, so the
  adaptive loop caps both phases; fixtures that lift that budget measure a
  regime the app cannot reach.

Migrating aggregation was rejected on feasibility. There is no library-wide
route-point limit — `WorkoutImportResourceLimits` bounds a single workout — so a
whole-pass native aggregation call would require a new arbitrary whole-library
limit and would run uninterruptibly across the entire library, losing
per-workout cancellation. Keeping the call per-workout would require either a
retained native accumulator, which contradicts the engine contract that C++
retains nothing between calls, or a Swift-owned open-addressed table plus a
rehash boundary — materially more complex than the Swift changes that address
the same measured cost.

The bounded Swift optimization is complete: it mixes both coordinates into one
`Hasher` input, reserves each pass with capped adaptive advice, and updates the
global dictionary from the caller-owned native output through a private
nonescaping Interop closure. Production creates no per-workout cell array;
pointer lifetime, public models, equality, persistence, cancellation, and
native-call count are unchanged.

`scripts/run-personal-heatmap-benchmark.sh` remains the merge gate: complete
production builder against complete Swift builder oracle. The extra subtimings
it prints are independent diagnostics and are not additive components of that
total. It also runs the opt-in same-binary aggregation comparison. Profile the
remaining active production hotspots before selecting another C++ migration.

### Phase: Heart-Rate Training Load

Delivered as a four-PR stack (engine kernel → Core profile/calculator/backfill → Trends panel → Settings + docs):

- [x] Engine: one summary-only `compute_training_load` bulk call (Banister TRIMP, five-zone seconds, coverage) with native hand-computed tests, bridge parity, and validator wiring
- [x] Core: `AthleteProfile` + local store, `TrainingLoadCalculator` (same-segment intervals, 300 s / 50% measured floors, conservative pace/duration estimator), `RunWorkout.trainingLoad` records-pattern marker (nil = backfill, profile mismatch = stale; no `analysisVersion` bump, `loadLibrary` untouched), resumable store-actor backfill
- [x] Trends: `TrainingLoadRollup` daily series with the zero-contribution rule (no-HR days flagged, never rest days), CTL/ATL/TSB recursion (42/7 defaults), estimated-excluded-by-default with explicit opt-in, HR-coverage disclosure, hover/VoiceOver summaries, one-pass backfill trigger honouring the library-level revision discipline
- [x] Settings: athlete profile form with derived-value disclosure (Tanaka estimate, population defaults), coefficient set offered but never required, explicit "Recompute Training Loads" with progress/cancel, and docs/training-load.md

### Phase: Analysis Enhancements
- [x] Personal heatmap across multiple runs
- [x] Automatic route grouping (Routes workspace) — two-stage matching (Swift facts filter + the existing constrained-DTW boundary, no second DTW), mutual coverage ≥ 0.90 at a 100 m unmatched budget (matched distance on both routes from the single solve; containment deliberately not grouped — the superset rule was reversed by product decision, manual merge is the recovery path) / median ≤ 35 m / p90 ≤ 100 m thresholds, opposite-direction grouping with reversed-member marking, derived-plus-pinnable representatives, manifest schema v4 with nil-marker assignment records, asynchronous post-import assignment and one-write re-cluster under the library-level revision discipline, descriptive no-geocoding names, rename/merge/remove/pin controls, All Runs + Personal Heatmap route filters, and a filtered-vs-brute-force benchmark on a 2,000-workout synthetic library
- [x] Trends workspace across the whole library — week/month/year aggregation of distance, active time, run count, weighted active pace, active-weighted HR, and corrected-else-raw ascent from stored summaries; period/range/scope filters with smart-collection scoping, click-through to period-filtered All Runs, recorded-offset local-date bucketing with whole-period range snapping, gap-not-zero rendering with contributing-run disclosure, session-v3 restoration, and persisted raw ascent totals (analysis version 6)
- [x] Personal records across the library — five extra fixed-distance fastest windows (1 mile, 5 km, 10 km, half marathon, marathon) added to the single native segment-detection call plus longest run and corrected-else-raw biggest ascent from summaries; per-workout windows stored on the snapshot behind a nil backfill marker (no analysis-version bump), one-off resumable actor backfill with inline progress and cancellation, Records workspace with scoped standing-best tables and strict-improvement history (last 10), click-through that opens the workout at the window start with map/chart range highlight, whole-library standing-record chips on Overview, Segments panel extended with attempted long windows, session-v4 restoration
- [x] Route coloring by pace or HR on map polyline (native MapKit; relative workout scale; corrected elevation)
- [x] Dynamic time warping for comparison (Route-Aware alignment; Distance mode retained)

### Phase: macOS v0.1 release readiness
Tooling and documentation for a reproducible release pipeline. Items marked
complete refer to **in-repo pipeline readiness**, not publication of an official
binary.

- [x] Authoritative `VERSION` file and build-number policy
- [x] Staged shared app-bundle assembly + Info.plist template (release, demo,
  and development launcher)
- [x] Preserve unsigned demo packaging path
- [x] Release packager (unsigned / ad-hoc / Developer ID CLI)
- [x] Ad-hoc dry-run path without Apple credentials
- [x] Signing workflow design (hardened runtime, inside-out, verify)
- [x] Notarization workflow design (`notarytool`, staple, Gatekeeper, final zip)
- [x] Versioned artifacts, `SHA256SUMS`, machine-readable release manifest
- [x] GitHub Actions `release.yml` (dry-run dispatch + annotated-tag production
  path with `main` ancestry and downloaded-artifact validation)
- [x] Credential-free packaging tests in PR CI
- [x] `docs/releasing.md` and v0.1.0 release notes
- [ ] Production Developer ID signing with owner credentials
- [ ] Production notarization + staple with owner credentials
- [ ] Production GitHub Release / official binary publication
- [ ] Annotated `v0.1.0` tag created by owner

See [docs/releasing.md](releasing.md). This phase does not add iOS, HealthKit,
Sparkle, DMG, or Intel builds.


## Strava bulk-export import (implemented)

Local-only ZIP import of running activities with review UI, secure path handling,
GZIP support, provenance/dedup, and staged batch commits. Not a Strava API client.

## Multi-session FIT import (implemented)

Import File… scans `.fit` containers off the main actor. Zero or one session
message keeps the existing direct single-workout path; two or more open the
Import FIT Sessions review sheet, where supported running sessions become
separate workouts committed in one staged transaction. Sport policy, boundary
resolution, attribution, identity, and limits are documented in
[import-formats.md](import-formats.md).

## FIT developer data import (implemented)

FIT developer data fields are decoded (field_description 206,
developer_data_id 207, record developer payloads resolved after parse so
out-of-order descriptions work), recognized by field name with the
application identity retained as provenance, and mapped onto route-point
power and running-dynamics fields. Unrecognized fields persist as metadata
plus min/max/mean statistics — never per-point value series — capped at 16
retained fields with truncation notes. Native record power also decodes and
loses to a developer power field with the conflict reported. No snapshot
version changes: legacy snapshots decode the new keys as nil and reimporting
the source file adds the data, exactly like recorded laps and training load.
See [import-formats.md](import-formats.md) for the decode, recognition, and
retention policy.
