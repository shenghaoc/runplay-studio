# RunPlay Studio — Phase Plan

## Phase 1: Foundation ✅ (Current)
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

## Phase 2: GPX Hardening
- [ ] Improve GPX parser robustness
- [ ] Handle GPX extensions (heart rate, cadence)
- [ ] Validate against real-world GPX files
- [ ] Add error reporting for malformed GPX

## Phase 3: TCX Import
- [ ] Parse TCX XML structure
- [ ] Extract trackpoints with timestamps
- [ ] Handle TCX sport types
- [ ] Map TCX data to RoutePoint model

## Phase 4: FIT Import
- [ ] Implement FIT binary format parser
- [ ] Extract record messages
- [ ] Handle FIT timestamps and coordinates
- [ ] Add FIT-specific error handling

## Phase 5: 3D Enhancements
- [ ] Route coloring by pace (gradient)
- [ ] Route coloring by heart rate
- [ ] Improve camera orbit controls
- [ ] Add elevation exaggeration slider
- [ ] Improve ground plane rendering

## Phase 6: Chart Interactivity
- [ ] Scrub charts to sync with 3D view
- [ ] Hover to highlight route position
- [ ] Click to seek replay
- [ ] Zoom/pan on charts

## Phase 7: Segment Detection
- [ ] Auto-detect fastest kilometers
- [ ] Auto-detect steepest climbs
- [ ] Highlight segments on 3D route
- [ ] Segment comparison table

## Phase 8: Route Comparison
- [ ] Load multiple workouts
- [ ] Side-by-side route comparison
- [ ] Split comparison table
- [ ] Overlay routes on same map

## Phase 9: Export
- [ ] Export summary as PNG
- [ ] Export route image
- [ ] Export split table as CSV
- [ ] Research video export with AVFoundation

## Phase 10: HealthKit Research
- [ ] Research macOS HealthKit availability
- [ ] Design HealthKit import flow
- [ ] Implement HealthKit workout query
- [ ] Handle permissions and privacy

## Phase 11: Polish
- [ ] Keyboard shortcuts
- [ ] Menu bar integration
- [ ] Window state persistence
- [ ] Accessibility improvements
- [ ] Performance optimization
