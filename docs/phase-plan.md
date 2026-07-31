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
- [x] Profile remaining core hotspots: `RemainingCoreHotspotProfile` covers analysis, alignment, metrics, import, and comparison families; results inform the migration roadmap below.
- [ ] **Migrate MovementProfile to C++23**: standalone two-pass movement-state classification (59 ms at 500 kpts, 24% of analysis wall). Highest-scoring candidate (4.45/5) — pure numeric, uses inline Haversine, well-bounded parity. One bulk call: `classify_movement_states(routePoints, activeSeconds, policy) → (states, movingCum, stoppedCum, diagnostics)`.
- [ ] **Migrate ElevationProfile to C++23**: multi-pass elevation correction (30 ms at 500 kpts). Second after MovementProfile; SegmentDetector depends on both.
- [ ] **Migrate SegmentDetector to C++23**: sliding-window pace/elevation detection (190 ms at 500 kpts, 77% of analysis wall). Highest absolute cost but blocked on MovementProfile + ElevationProfile migration.
- [ ] **Legacy SceneKit projection remains low priority** unless it regains a shipped caller

**Not recommended for migration**: MetricSmoother (sub-ms), import parsers (I/O-bound), RouteAlignmentSampleBuilder (infrequent, 2k cap), SplitCalculator (auto-resolves after deps).

Swift performs route-size validation, basic field sanitization, sorting,
initial source-segment compaction, source-speed validation, elevation,
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
