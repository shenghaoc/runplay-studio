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

---

## Active / Upcoming Phases

### Phase: HealthKit Research (Future)
- [ ] Research macOS HealthKit entitlements and availability
- [ ] Design import flow and privacy model
- [ ] Implement HealthKit workout query and importer

### Phase: Advanced Export
- [x] Dark mode PNG summary card variant
- [x] Map region screenshot in PNG export
- [ ] Video export (AVFoundation) — post-MVP

### Phase: Polish and Accessibility
- [x] Keyboard shortcuts for replay and navigation
- [x] Accessibility labels and VoiceOver support audit
- [x] Window state persistence across relaunches

### Phase: Expanded Import
- [x] Strava export (.zip) importer
- [x] Multi-session FIT batch import
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
- [ ] **Final portable-core cleanup** (mandatory endpoint): transitional step-distance boundary disposition, public C++ boundary inventory, raw-pointer exception review, dead Swift oracle/duplicate removal, benchmark inventory, sanitizer matrix, package-consumer smoke, architecture docs, future iOS portability review.
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
| Minimum | 1 | Final cleanup |
| Expected | 1 | Final cleanup |
| Maximum reasonable | 2 | Final cleanup plus a targeted Swift optimization only if new evidence justifies it |

Swift performs route-size validation, basic field sanitization, sorting,
initial source-segment compaction, source-speed validation,
diagnostics translation, public models, and persistence.

C++ performs production outlier evidence, isolated-point rejection, implicit
gap inference, final segment compaction, supplied-distance policy, and
normalized cumulative distances through one bulk call.

The standalone step-distance boundary remains transitional/test-focused. No
scalar per-point Swift/C++ production calls are allowed. No persisted schema,
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
tax was roughly 0.9 ms of a step-distance bridge call. Migrating each geometric
stage separately would pay it repeatedly; migrating them together pays it once.

The combined kernel reuses internal pairwise step logic rather than invoking
the public step-distance boundary. Product limit (1,000,000 points) and engine
ceiling (1,250,000 samples) are unchanged.

`scripts/run-route-quality-benchmark.sh` compares complete Swift stages 2–4
against the complete combined bridge (including conversion). The historical
step-distance script remains available for the transitional boundary.

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

### Phase: Analysis Enhancements
- [x] Personal heatmap across multiple runs
- [x] Route coloring by pace or HR on map polyline (native MapKit; relative workout scale; corrected elevation)
- [x] Dynamic time warping for comparison (Route-Aware alignment; Distance mode retained)


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
