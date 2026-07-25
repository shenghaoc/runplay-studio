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
- [ ] Strava export (.zip) importer
- [ ] Multi-session FIT batch import
- [ ] iPhone companion exporter (future)

### Phase: Analysis Enhancements
- [x] Personal heatmap across multiple runs
- [x] Route coloring by pace or HR on map polyline (native MapKit; relative workout scale; corrected elevation)
- [ ] Dynamic time warping for comparison (post-MVP)


## Strava bulk-export import (implemented)

Local-only ZIP import of running activities with review UI, secure path handling,
GZIP support, provenance/dedup, and staged batch commits. Not a Strava API client.
