# RunPlay Studio — Phase Plan

## Phase 1: Foundation ✅
- [x] Initialize repository
- [x] Create documentation
- [x] Define data models
- [x] Create sample JSON fixture
- [x] Implement JSON importer
- [x] Implement workout analysis
- [x] Implement route projection
- [x] Implement replay controller
- [x] Build 3D route scene
- [x] Build 2D MapKit view
- [x] Build Swift Charts views
- [x] Build SwiftUI shell
- [x] Add unit tests

## Phase 2: GPX Import ✅
- [x] Basic GPX parser with XML parsing
- [x] Handle GPX extensions (heart rate, cadence)
- [ ] Validate against real-world GPX files (use realistic_5k_run.gpx fixture)
- [ ] Add error reporting for malformed GPX

## Phase 3: 3D Route Replay Polish ✅
- [x] Improve route geometry (skip zero-length segments)
- [x] Better lighting (key + fill + top lights)
- [x] Direction-aware replay marker (cone)
- [x] Start/finish markers with labels
- [x] Kilometer markers with poles
- [x] Adaptive ground grid
- [x] Camera presets (default, top-down, side)
- [x] Fit-to-route camera button
- [x] Camera controller wired to the visible SceneKit point of view
- [x] Elevation exaggeration controls (1x, 2x, 5x, 10x)
- [x] Grid and km marker visibility toggles

## Phase 4: Route Coloring ✅
- [x] Route coloring by pace (blue=fast, red=slow)
- [x] Quantile-based color scaling (10th/90th percentile)
- [x] Moving average smoothing for pace
- [x] Elevation coloring (green=low, brown=high)
- [x] Color mode picker (Single/Pace/Elevation)
- [x] Pace legend with gradient bar

## Phase 5: Synchronized Replay ✅
- [x] Unified ReplayController as single source of truth
- [x] 3D marker sync with timeline
- [x] 2D map marker sync
- [x] Chart selection indicator (RuleMark)
- [x] Current metrics panel (time, distance, pace, elev, HR, split)
- [x] Split table current split highlighting
- [x] Playback controls (play/pause/stop/speed)

## Phase 6: Segment Detection ✅
- [x] Fastest 400m detection (distance-based sliding window)
- [x] Fastest 1km detection
- [x] Slowest 1km detection
- [x] Biggest climb detection
- [x] Biggest descent detection
- [x] Segment highlights panel with cards
- [x] 3D segment highlighting (translucent tube above route)
- [x] Segment start/end markers

## Phase 7: Export ✅
- [x] JSON summary export (complete workout data)
- [x] Splits CSV export
- [x] Segments CSV export
- [x] Combined CSV export
- [x] PNG summary card export (1200×1600)
- [x] Export menu with NSSavePanel
- [x] Safe filename generation
- [x] CSV escaping for special characters
- [x] Bundled synthetic export smoke coverage
- [x] Synthetic demo summary PNG under docs/assets
- [ ] Manual save-panel export smoke in a normal desktop session

## Phase 8: Chart Click-to-Seek ✅
- [x] Click/drag on chart to seek replay position
- [x] Chart selection mapping helpers
- [x] Visual feedback during chart interaction
- [x] Playback behavior: pauses during chart drag

## Phase 9: TCX Import ✅
- [x] Parse TCX XML structure
- [x] Extract trackpoints with timestamps
- [x] Handle TCX sport types
- [x] Map TCX data to RoutePoint model
- [x] Support multiple laps
- [x] Parse heart rate and cadence
- [x] Handle missing fields gracefully

## Phase 10: FIT Import ✅
- [x] Implement FIT binary format parser
- [x] Extract record messages
- [x] Handle FIT timestamps and coordinates
- [x] Add FIT-specific error handling
- [x] Parse altitude, speed, heart rate, cadence
- [x] Semicircle to degree coordinate conversion
- [x] Wire into file picker

## Phase 11: Route Comparison ✅
- [x] ComparisonPair, WorkoutComparisonSummary, SplitComparison, ComparisonMetricPoint, and ComparisonWarning models
- [x] WorkoutComparisonService with distance-based alignment
- [x] Summary metric deltas
- [x] Average and max heart-rate deltas when available
- [x] Split comparison aligned by split index
- [x] Pace-over-distance comparison series clamped to common distance
- [x] 2D MapKit route overlay with primary/comparison legend
- [x] Compare view and comparison selection state
- [x] Warnings for different distances, insufficient overlap, different route endpoints, missing data, and too few points
- [x] Pure logic tests for comparison edge cases
- [x] Bundled comparison demo fixture for immediate dogfooding
- [x] Manual GUI dogfooding with bundled runs and a local TCX import
- [x] macOS 14 MapKit overlay API modernization for route maps
- [x] Clearer distance-alignment warning for different route shapes
- [x] 3D comparison overlay
- [x] 3D comparison camera controller wired to the visible SceneKit point of view
- [x] 3D comparison selected-distance markers with time/pace delta readout
- [ ] Manual GUI recheck of single-run and comparison 3D camera buttons after camera wiring fix

## Phase 11.5: Real-Data Safety And Demo Polish ✅
- [x] Ignore local private workout paths and `activity_*.tcx` / `activity_*.fit`
- [x] Document private workout data policy
- [x] Expand manual privacy and export dogfood checklists
- [x] Add synthetic README demo image
- [x] Keep private workout files out of committed fixtures and assets

## Phase 12: HealthKit Research (Future)
- [ ] Research macOS HealthKit availability
- [ ] Design HealthKit import flow
- [ ] Implement HealthKit workout query
- [ ] Handle permissions and privacy

## Phase 13: Advanced Features
- [x] Heart rate route coloring
- [ ] Dark mode PNG variant
- [ ] Map/3D screenshot in PNG export
- [ ] Keyboard shortcuts
- [ ] Window state persistence
- [ ] Accessibility improvements
