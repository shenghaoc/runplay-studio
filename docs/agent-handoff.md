# RunPlay Studio - Agent Handoff

## Current Status

3D route comparison overlay MVP is implemented. Route comparison now supports
both 2D map and 3D scene views. Do not add commit hashes to this handoff as a
status field; they become stale and cause repeated hash-only documentation
commits during rapid iteration. Run `git log -1 --oneline` locally to see the
current commit.

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
- `swift test`: pass, 227 tests, 0 failures
- Package product: `RunPlayStudio`
- Test target: `RunPlayStudioTests`
- Validation was performed after synchronizing with the latest default branch

## Completed Capabilities

- Local import: JSON, GPX, TCX, and basic FIT activity files
- 3D route replay with SceneKit
- 2D MapKit route view
- Swift Charts pace, elevation, and heart-rate metrics
- Pace, elevation, and heart-rate route coloring
- Synchronized replay state across 3D, map, charts, metrics, and split table
- Chart click/drag-to-seek
- Segment detection and 3D segment highlighting
- Local JSON, CSV, and PNG summary export
- Route comparison MVP
- 3D route comparison overlay
- Bundled demo comparison pair loaded on launch for immediate comparison testing
- Private local workout ignore policy and data-handling documentation
- Synthetic demo summary PNG generated from bundled fixture data

## Route Comparison MVP

Implemented files:

- `RunPlayStudio/Sources/Models/WorkoutComparison.swift`
- `RunPlayStudio/Sources/Models/ComparisonRouteScene.swift`
- `RunPlayStudio/Sources/Services/WorkoutComparisonService.swift`
- `RunPlayStudio/Sources/Services/ComparisonRouteProjectionService.swift`
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
  distance
- Shows a 2D route overlay for both runs with a simple legend
- Shows a 3D comparison overlay with both routes in the same scene
- 3D comparison uses shared coordinate origin (primary route center) so both
  routes maintain correct relative geographic positioning
- 3D comparison shows primary (blue) and comparison (orange) routes with
  distinct start/finish markers and a 3D legend
- 3D comparison supports elevation exaggeration, camera presets, fit-to-routes,
  and grid toggle
- Toggle between 2D map and 3D view via segmented picker in CompareView
- Shows warnings for different distances, insufficient overlap, different route
  endpoints, missing heart rate, missing elevation, and too few points
- Rejects comparing a selected primary workout with itself
- Formats deltas with faster/slower and longer/shorter direction labels
- Keeps all comparison work local to the app
- The route-shape warning now explicitly says comparison uses distance alignment

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

Remaining export gap:

- GUI save-panel writing of JSON, CSV, and PNG still needs a normal desktop
  manual pass. The export menu was previously verified, and export generation is
  covered by tests, but the save-panel write itself was not completed in this
  automated session.

## Manual GUI Dogfood

Manual dogfood was run from a temporary SwiftPM-built app bundle after a clean
repository sync.

Verified:

- App launched with the two bundled demo runs loaded
- Existing 3D single-run replay rendered and stayed usable
- Compare view opened from the toolbar
- Primary/comparison selector excluded the current primary workout
- Summary delta cards rendered with faster/slower direction labels
- Split comparison table rendered
- Pace-over-distance comparison chart rendered
- 2D comparison map overlay and primary/comparison legend rendered
- Selecting a different primary cleared comparison mode safely
- A user-provided local TCX file imported through the visible Import control
- Comparing that shorter TCX run against a bundled run showed different-distance
  and different-route warnings instead of crashing
- Export menu still exposed JSON, CSV, segment CSV, PNG, and combined CSV actions
- Synthetic export smoke coverage passed at the service/model level

Not fully completed manually:

- A save-panel export was not written during dogfood to avoid browsing outside
  the repo or temporary paths. Export data generation and PNG rendering are
  covered by automated `ExportServiceTests`.

## MapKit Status

The comparison and single-route MapKit views now use the macOS 14 `Map` APIs
with `MapPolyline`, `Annotation`, and `MapCameraPosition`. The previous
deprecation warnings from route map overlays are removed in current builds.

## Recommended Next Phase

Stabilize 3D comparison after broader real-workout dogfooding:

- GUI dogfood the 3D comparison view with bundled demo runs
- GUI dogfood the save-panel export in a normal desktop session
- Improve comparison chart readability when routes differ substantially
- Consider a selected-distance marker on both routes in 3D comparison
- Keep expanding synthetic demo assets only from anonymized or generated data
- Keep HealthKit, cloud, accounts, telemetry, analytics, AI APIs, and advanced
  route matching out of scope until explicitly planned
