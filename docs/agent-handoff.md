# RunPlay Studio - Agent Handoff

## Current Status

The earlier SceneKit GUI checklist is superseded. The current product uses one
SwiftUI MapKit surface with a native 2D/3D pitch toggle. Current verification
belongs in `docs/manual-testing.md`. Do not add commit hashes to this handoff as a status field;
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
- `swift test`: pass
- Package products: `RunPlayCore`, `RunPlayStudio`
- Test targets: `RunPlayCoreTests`, `RunPlayStudioTests`

## Completed Capabilities

- Local import: JSON, GPX, TCX, and basic FIT activity files
- Import normalization rejects invalid coordinates, requires at least one
  GPX/TCX/FIT timestamp for timing analysis, interpolates partial missing
  timestamps, rebases first nonzero TCX/FIT distances, and prevents mixed
  supplied/computed distance series
- One SwiftUI MapKit route view with flat 2D and realistic-elevation 3D modes
- Swift Charts pace, elevation, and heart-rate metrics
- Synchronized replay state across map, charts, metrics, and split table
- Chart click/drag-to-seek
- Segment detection and seekable segment cards
- Local JSON, CSV, and PNG summary export
- Explicit export result formats for JSON, splits CSV, segments CSV, combined
  CSV, and PNG
- Route comparison MVP
- Shared 2D/3D Apple Maps comparison overlay
- Comparison selected-distance markers with time/pace delta readout
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
- `RunPlayStudio/Sources/Views/ComparisonMapView.swift`
- `RunPlayStudio/Sources/Views/RouteMapCanvas.swift`
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
- Shows both routes on one SwiftUI MapKit surface with a simple legend
- The native pitch toggle switches the same overlay between flat and realistic
  elevation while preserving primary (blue) and comparison (orange) routes
- The comparison map supports a selected-distance slider that places interpolated
  markers on both routes at the same distance, with a compact readout showing
  elapsed time and pace deltas. Distance is clamped to the common route distance.
- Toggle between 2D and 3D with MapKit's map pitch control
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

The following non-map workflows were verified by the human owner on 2026-07-08.
The current MapKit 2D/3D refactor requires the newer checklist below.

Verified:

- App launched with the two bundled demo runs loaded
- Single-run MapKit route view rendered and stayed usable
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
- Map and Charts tabs work when selected
- Delete UI: context menu, confirmation dialog, deletion all work correctly
- Comparison mode clears when comparison workout is deleted
- Empty state appears when last workout is deleted

## Apple Maps 2D/3D GUI Dogfood

The current map path is `RouteMapCanvas`, a SwiftUI `Map` shared by single-run
and comparison views. It uses one in-map camera toggle and realistic elevation,
and `MapCameraPosition`; there is no separate SceneKit product view.

Verify with the bundled synthetic runs:

- One map remains mounted while the pitch toggle changes 2D/3D presentation
- Route lines and replay/selected-distance markers remain geospatially aligned
- Primary stays blue and comparison stays orange
- Fit Route/Fit Routes works in both pitch states
- Pan, rotate, zoom, compass, scale, and zoom stepper remain usable
- The comparison slider and time/pace readout continue updating in both states

Computer Use verification on 2026-07-10 confirmed the single-run and comparison
toggles in both directions. At 3.70 km, both comparison markers and the
time/pace delta readout remained present after toggling back to 2D.

## MapKit Status

The comparison and single-route MapKit views now use the macOS 14 `Map` APIs
with `MapPolyline`, `Annotation`, and `MapCameraPosition`. The previous
deprecation warnings from route map overlays are removed in current builds.

## Recommended Next Phase

After completing the current MapKit checklist, next steps are:

- Add comparison demo screenshot to docs/assets/ when available
- Keep expanding synthetic demo assets only from anonymized or generated data
- Keep HealthKit, cloud, accounts, telemetry, analytics, AI APIs, and advanced
  route matching out of scope until explicitly planned
