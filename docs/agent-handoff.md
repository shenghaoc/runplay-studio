# RunPlay Studio - Agent Handoff

## Current Status

Route comparison MVP dogfood and UX polish are implemented and verified from
the SwiftPM package.
Do not add commit hashes to this handoff as a status field; they become stale and
caused repeated hash-only documentation commits during rapid iteration.
Run `git log -1 --oneline` locally to see the current commit.

## Verification Snapshot

Run from repository root:

```bash
git status
swift build
swift test
```

Latest verified result:

- `swift build`: pass
- `swift test`: pass, 204 tests, 0 failures
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
- Bundled demo comparison pair loaded on launch for immediate comparison testing

## Route Comparison MVP

Implemented files:

- `RunPlayStudio/Sources/Models/WorkoutComparison.swift`
- `RunPlayStudio/Sources/Services/WorkoutComparisonService.swift`
- `RunPlayStudio/Sources/ViewModels/AppState.swift`
- `RunPlayStudio/Sources/Views/CompareView.swift`
- `RunPlayStudio/Sources/Views/ComparisonMapView.swift`
- `RunPlayStudio/Sources/Views/ComparisonChartView.swift`
- `RunPlayStudio/Resources/fixtures/comparison_park_run.json`
- `RunPlayStudio/Tests/RunPlayStudioTests/AppStateComparisonTests.swift`
- `RunPlayStudio/Tests/RunPlayStudioTests/WorkoutComparisonTests.swift`

Current comparison behavior:

- Compares the selected workout as Primary against one loaded Comparison workout
- Reports summary deltas for distance, duration, average pace, elevation gain,
  average heart rate, and max heart rate when available
- Aligns splits by split index
- Builds a distance-aligned pace/elevation/heart-rate series clamped to common
  distance
- Shows a 2D route overlay for both runs with a simple legend
- Shows warnings for different distances, insufficient overlap, different route
  endpoints, missing heart rate, missing elevation, and too few points
- Rejects comparing a selected primary workout with itself
- Formats deltas with faster/slower and longer/shorter direction labels
- Keeps all comparison work local to the app

Current comparison limitations:

- No dynamic time warping or complex route matching
- No 3D route comparison overlay
- No chart hover, zoom, or pan behavior for comparison charts
- No HealthKit, cloud sync, accounts, telemetry, analytics, or AI APIs

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

Not fully completed manually:

- A save-panel export was not written during dogfood to avoid browsing outside
  the repo or temporary paths. Export data generation remains covered by
  automated `ExportServiceTests`.

## MapKit Status

The comparison and single-route MapKit views now use the macOS 14 `Map` APIs
with `MapPolyline`, `Annotation`, and `MapCameraPosition`. The previous
deprecation warnings from route map overlays are removed in current builds.

## Recommended Next Phase

Stabilize comparison after broader real-workout dogfooding:

- Improve comparison chart readability when routes differ substantially
- Consider a safe, optional 3D overlay only after 2D comparison is stable
- Broaden manual export smoke testing in a normal desktop session
- Keep HealthKit, cloud, accounts, telemetry, analytics, AI APIs, and advanced
  route matching out of scope until explicitly planned
