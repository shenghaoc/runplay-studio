# RunPlay Studio - Agent Handoff

## Current Status

All manual GUI checklists are complete. Human owner verified on 2026-07-08:
3D camera controls, 3D comparison view, selected-distance slider, comparison
chart readability, save-panel JSON/CSV/PNG export, default view, delete UI,
and HR color mode. Do not add commit hashes to this handoff as a status field;
they become stale and cause repeated hash-only documentation commits during
rapid iteration. Run `git log -1 --oneline` locally to see the current commit.

## Verification Snapshot

Run from repository root:

```bash
git status
git fetch origin
swift build
swift test
```

Latest verified result:

- `swift build`: pass
- `swift test --filter RunPlayCoreTests`: pass, core tests, 0 failures
- `swift test`: pass, 433 tests, 0 failures
- Package products: `RunPlayCore`, `RunPlayStudio`
- Test targets: `RunPlayCoreTests`, `RunPlayStudioTests`

## Completed Capabilities

- Local import: JSON, GPX, TCX, and basic FIT activity files
- Import normalization rejects invalid coordinates, requires at least one
  GPX/TCX/FIT timestamp for timing analysis, interpolates partial missing
  timestamps, rebases first nonzero TCX/FIT distances, and prevents mixed
  supplied/computed distance series
- 3D route replay with SceneKit
- 2D MapKit route view
- Swift Charts pace, elevation, and heart-rate metrics
- Pace, elevation, and heart-rate route coloring
- Synchronized replay state across 3D, map, charts, metrics, and split table
- Chart click/drag-to-seek
- Segment detection and 3D segment highlighting
- Local JSON, CSV, and PNG summary export
- Explicit export result formats for JSON, splits CSV, segments CSV, combined
  CSV, and PNG
- Route comparison MVP
- 3D route comparison overlay
- 3D comparison selected-distance markers with time/pace delta readout
- SceneKit camera controls wired to the visible single-run and comparison scenes
- Bundled demo comparison pair loaded on launch for immediate comparison testing
- Comparison chart uses actual workout names in legend, min/km units on axes
  and table headers, and proper empty states
- Comparison warnings show common distance when routes differ significantly
- Private local workout ignore policy and data-handling documentation
- Synthetic demo summary PNG generated from bundled fixture data
- Demo script for 3–5 minute public walkthrough

## Route Comparison MVP

Implemented files (models and services in `RunPlayCore`, UI in `RunPlayStudio`):

- `RunPlayCore/Sources/Models/WorkoutComparison.swift`
- `RunPlayCore/Sources/Models/ComparisonRouteScene.swift`
- `RunPlayCore/Sources/Services/WorkoutComparisonService.swift`
- `RunPlayCore/Sources/Services/ComparisonRouteProjectionService.swift`
- `RunPlayStudio/Sources/ViewModels/AppState.swift`
- `RunPlayStudio/Sources/Views/CompareView.swift`
- `RunPlayStudio/Sources/Views/ComparisonMapView.swift`
- `RunPlayStudio/Sources/Views/ComparisonChartView.swift`
- `RunPlayStudio/Sources/Views/Comparison3DView.swift`
- `RunPlayStudio/Sources/3D/ComparisonSceneBuilder.swift`
- `RunPlayStudio/Resources/fixtures/comparison_park_run.json`
- `RunPlayStudio/Tests/RunPlayStudioTests/AppStateComparisonTests.swift`
- `RunPlayStudio/Tests/RunPlayStudioTests/WorkoutComparisonTests.swift`
- `RunPlayStudio/Tests/RunPlayStudioTests/ComparisonProjectionTests.swift`

Current comparison behavior:

- Compares the selected workout as Primary against one loaded Comparison workout
- Reports summary deltas for distance, duration, average pace, elevation gain,
  average heart rate, and max heart rate when available
- Aligns splits by split index
- Builds a distance-aligned pace/elevation/heart-rate series clamped to common
  distance using interpolated route points
- Shows a 2D route overlay for both runs with a simple legend
- Shows a 3D comparison overlay with both routes in the same scene
- 3D comparison uses shared coordinate origin (primary route center) so both
  routes maintain correct relative geographic positioning
- 3D comparison shows primary (blue) and comparison (orange) routes with
  distinct start/finish markers and a 3D legend
- 3D comparison supports elevation exaggeration, camera presets, fit-to-routes,
  and grid toggle. Camera wiring and builder visibility toggles are covered by
  tests; run a normal desktop manual pass before marking the buttons GUI-verified.
- 3D comparison supports a selected-distance slider that places interpolated
  markers on both routes at the same distance, with a compact readout showing
  elapsed time and pace deltas. Distance is clamped to the common route distance.
- Toggle between 2D map and 3D view via segmented picker in CompareView
- Shows warnings for different distances, insufficient overlap, different route
  endpoints, missing heart rate, missing elevation, and too few points
- Rejects comparing a selected primary workout with itself
- Formats deltas with faster/slower and longer/shorter direction labels
- Keeps all comparison work local to the app
- The route-shape warning explicitly states comparison uses distance alignment
  and samples shared distances

Current comparison limitations:

- No dynamic time warping or complex route matching
- No chart hover, zoom, or pan behavior for comparison charts
- No HealthKit, cloud sync, accounts, telemetry, analytics, or AI APIs

## Private Data Safety

Implemented:

- `.gitignore` excludes `local-workouts/`, `private-workouts/`,
  `*.local.gpx`, `*.local.tcx`, `*.local.fit`, `activity_*.tcx`, and
  `activity_*.fit`
- `docs/private-data.md` documents that real workout files, screenshots, and
  exports generated from private workouts must not be committed
- Manual testing docs include a pre-commit privacy checklist and explicit
  staging guidance

When private workout files are present, use explicit `git add <path>` and
verify `git diff --cached --name-status` before committing. Do not use
`git add -A`.

## Export Smoke

Implemented:

- `ExportServiceTests` now smoke-tests bundled synthetic demo export paths for
  JSON summary, splits CSV, segments CSV, combined CSV, and PNG summary output
- Demo export text is checked for private-data markers
- `docs/assets/demo-summary.png` is generated from bundled synthetic
  `sample_run.json` and visually inspected
- PNG rendering was hardened so fixed-size SwiftUI export cards get a concrete
  hosting view size before bitmap capture

Export gap resolved:

- GUI save-panel writing of JSON, CSV, and PNG confirmed working in manual GUI
  pass on 2026-07-08. The export menu and export generation were previously
  verified by automated `ExportServiceTests`.

## Manual GUI Dogfood

All manual GUI checklists verified by human owner on 2026-07-08.

Verified:

- App launched with the two bundled demo runs loaded
- Existing 3D single-run replay rendered and stayed usable
- Compare view opened from the toolbar
- Primary/comparison selector excluded the current primary workout
- Summary delta cards rendered with faster/slower direction labels
- Split comparison table rendered
- Pace-over-distance comparison chart rendered with actual workout names in legend
- Chart axes show Distance (km) and min/km; subtitle says "lower is faster"
- 2D comparison map overlay and primary/comparison legend rendered
- Selecting a different primary cleared comparison mode safely
- A user-provided local TCX file imported through the visible Import control
- Comparing that shorter TCX run against a bundled run showed different-distance
  and different-route warnings instead of crashing
- Export menu still exposed JSON, CSV, segment CSV, PNG, and combined CSV actions
- Synthetic export smoke coverage passed at the service/model level
- Save-panel export of JSON, CSV, and PNG confirmed working (2026-07-08)
- Comparison chart readability improvements verified (legend, units, empty states)
- Default view shows Overview tab with map, route overlay, summary metrics, replay controls
- All tabs (3D Route, Charts, Map) work when selected
- Delete UI: context menu, confirmation dialog, deletion all work correctly
- Comparison mode clears when comparison workout is deleted
- Empty state appears when last workout is deleted
- HR color button disabled when route has no HR data, works when HR data present
- Tooltip explains disabled HR button state

## 3D Comparison GUI Dogfood

GUI dogfood of the 3D comparison view was performed using bundled synthetic
demo runs. A manual GUI pass on 2026-07-08 confirmed all camera controls and
3D comparison features work correctly.

Verified:

- App launches without crash from SwiftPM debug build
- Both bundled demo runs load automatically on launch
- Compare view opens from the toolbar
- Primary/comparison selectors work
- Same-workout comparison is blocked
- 2D comparison map still works
- 3D comparison toggle works (segmented picker)
- Both routes render in the 3D comparison scene
- Primary route (blue) and comparison route (orange) are visually distinguishable
- P START / P FINISH and C START / C FINISH markers appear
- Legend appears and is understandable
- Elevation exaggeration controls (1x, 2x, 5x, 10x) rebuild the scene
- Grid toggle shows/hides the ground grid
- Comparison warnings appear in the 3D view when applicable
- Switching between 2D and 3D comparison does not crash
- Switching back to single-run 3D replay still works
- Fit Routes button frames both routes correctly (2026-07-08)
- Camera presets (default, top-down, side, front) work in comparison (2026-07-08)
- Single-run Fit Route button works correctly (2026-07-08)
- Single-run camera presets work correctly (2026-07-08)
- Manual orbit/zoom/pan works after pressing presets (2026-07-08)

Camera-control fix completed:

- Single-run `Route3DReplayView` now passes the controller-owned camera node to
  `SceneView(pointOfView:)`.
- `Comparison3DView` now passes the controller-owned camera node to
  `SceneView(pointOfView:)`.
- `SceneCameraController` exposes the active camera node, clamps camera distance
  and fit math, and sanitizes non-finite bounds.
- `SceneCameraControllerTests` cover camera installation, fit-to-route math,
  presets, non-finite zoom input, and comparison-route camera bounds.

## 3D Comparison Selected-Distance Dogfood

All selected-distance slider items verified by human owner on 2026-07-08:

- Distance slider appears at the bottom of the 3D comparison view
- Distance readout shows "0.00 km / X.XX km" format
- "P X.XX km" and "C X.XX km" markers appear and move along routes when scrubbed
- Elapsed time and pace readouts update correctly with faster/slower direction
- Backward-end and forward-end buttons work correctly
- Camera presets, elevation scale, and grid toggle still work after slider interaction
- Switching back to 2D Map does not crash

Known limitations found:

- Grid toggle icon previously used the same SF Symbol for on/off state; the
  current code now uses filled/unfilled grid symbols, confirmed working in
  manual pass.

## MapKit Status

The comparison and single-route MapKit views now use the macOS 14 `Map` APIs
with `MapPolyline`, `Annotation`, and `MapCameraPosition`. The previous
deprecation warnings from route map overlays are removed in current builds.

## Recommended Next Phase

All GUI checklists verified. Next steps:

- Add comparison demo screenshot to docs/assets/ when available
- Keep expanding synthetic demo assets only from anonymized or generated data
- Consider tagging v0.1 demo release
- Keep HealthKit, cloud, accounts, telemetry, analytics, AI APIs, and advanced
  route matching out of scope until explicitly planned
