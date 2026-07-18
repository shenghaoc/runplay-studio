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
- JSON summary, splits CSV, segments CSV, combined CSV, PNG summary card (1200×1600)
- All exports local via NSSavePanel
- `ImageRenderer`-based PNG export (requires GUI context)

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

---

## Active / Upcoming Phases

### Phase: HealthKit Research (Future)
- [ ] Research macOS HealthKit entitlements and availability
- [ ] Design import flow and privacy model
- [ ] Implement HealthKit workout query and importer

### Phase: Advanced Export
- [ ] Dark mode PNG summary card variant
- [ ] Map region screenshot in PNG export
- [ ] Video export (AVFoundation) — post-MVP

### Phase: Polish and Accessibility
- [ ] Keyboard shortcuts for replay and navigation
- [ ] Accessibility labels and VoiceOver support audit
- [ ] Window state persistence across relaunches

### Phase: Expanded Import
- [ ] Strava export (.zip) importer
- [ ] Multi-session FIT batch import
- [ ] iPhone companion exporter (future)

### Phase: Analysis Enhancements
- [x] Personal heatmap across multiple runs
- [ ] Route coloring by pace or HR on map polyline
- [ ] Dynamic time warping for comparison (post-MVP)


## Strava bulk-export import (implemented)

Local-only ZIP import of running activities with review UI, secure path handling,
GZIP support, provenance/dedup, and staged batch commits. Not a Strava API client.
