---
inclusion: fileMatch
fileMatchPattern:
  - "RunPlayStudio/Sources/Views/**/*"
  - "RunPlayStudio/Sources/ViewModels/**/*"
  - "RunPlayStudio/Sources/Services/**/*"
  - "RunPlayStudio/Sources/RunPlayStudioApp.swift"
---

# RunPlay Studio — UI layer conventions

## Layer rules

`RunPlayStudio` owns all SwiftUI, Swift Charts, app lifecycle, and `@MainActor`
UI state. It must not be imported by `RunPlayPlatform` or `RunPlayCore`.

## Key types

| Type | Role |
|------|------|
| `AppState` | Central `@MainActor ObservableObject` coordinator. Owns `workouts`, `selectedWorkout`, `workspaceMode`, favourites, `replayController`, comparison state, `personalHeatmap`, `workoutLibrary`, and library operation state. |
| `AppWorkspaceMode` | Mutually exclusive top-level destinations: `.workout`, `.comparison`, `.personalHeatmap`, `.workoutLibrary` (All Runs). |
| `WorkoutLibraryViewModel` | All Runs search/filter/sort/tag state, smart-collection query context, multi-select, search documents, cancellable off-main queries, stale-result suppression. |
| `WorkoutLibraryView` | All Runs table UI (Tags column), filters, tag/collection sheets, Modified/Revert/Update chrome, empty states, metadata editor. |
| `WorkoutTagViews` | Tag chips, single/bulk tag editors, Manage Tags, Save/Manage Smart Collections. |
| `PersonalHeatmapViewModel` | Dedicated heatmap filters, background aggregation, stale-request suppression, and in-memory cache. |
| `PersonalHeatmapView` | Heatmap workspace UI: filters, statistics, map areas, legend, empty/loading/error states. |
| `ReplayController` | `@MainActor ObservableObject` wrapper around `PlaybackEngine`. Drives timeline, playback speed, and current route point. |
| `ContentView` | Root view. Hosts the sidebar and detail split. Owns the `.fileImporter` modifier and delegates import to `AppState`. |
| `WorkoutDetailView` | Detail host. Provides shared replay controls, metrics panel, and tab picker (Overview / Charts). |
| `OverviewView` | Default landing tab. Embeds `MapReferenceView` / `RouteMapCanvas` and passes the current point index from `ReplayController`. |
| `WorkoutRouteMapViewModel` | Single-workout metric route lines: off-main builds, cache, cancellation; does not rebuild on replay ticks. |
| `RouteMapCanvas` | Shared SwiftUI `Map` surface for single-run, comparison, and heatmap maps. Owns `MapCameraPosition`, optional `RouteMapArea` fills, and the 2D/3D pitch toggle. |
| `RouteMetricLegendView` | Focused numeric/no-data/accessibility legend for workout-relative route coloring. |
| `MetricsChartView` | Pace, elevation, HR, speed charts. Drag-to-seek pauses playback and updates `ReplayController`. |
| `CompareView` | Comparison host. Owns primary/comparison selection and delegates to `WorkoutComparisonService`. |

## Patterns

- `ContentView` owns `AppState` with `@StateObject`; dependent views use
  `@ObservedObject` for `AppState` and `ReplayController`.
- Chart drag-to-seek: `WorkoutDetailView` pauses `ReplayController`, then calls
  `seekToDistance(_:)` with the distance emitted by `MetricsChartView`.
- Map 2D/3D toggle: changes `MapCamera.pitch` on the shared `MapCameraPosition`
  — does not swap the map view or renderer.
- `RouteMapCanvas` is reused for single-run, comparison, and personal-heatmap
  maps; do not create a second map type. Heatmap uses filled `MapPolygon`
  areas under routes; heat intensity must not reuse primary-blue vs
  comparison-orange semantics. Route metric coloring applies only to the
  single-workout map; comparison stays blue/orange.
- Heatmap aggregation runs off the main actor via `PersonalHeatmapViewModel`
  and must not set global `LibraryOperationState` busy for the whole app.
- PNG export uses `ImageRenderer` on a concrete SwiftUI view
  (`ExportSummaryCardView`) at fixed 1200×1600 scale 1.0 — never `NSScreen` scale.
- Map-inclusive PNG uses Platform `WorkoutMapSnapshotting` + overlay composition;
  do not screenshot `RouteMapCanvas` or require Screen Recording.
- Export sheet + `PNGSummaryExportViewModel` own configuration, preview, and
  cancellation; keep workflow out of `AppState`.

## What belongs here vs. RunPlayCore

| Concern | Layer |
|---------|-------|
| SwiftUI views and modifiers | RunPlayStudio |
| `@MainActor` state, Combine publishers | RunPlayStudio |
| PNG rendering (`ImageRenderer`, export palettes) | RunPlayStudio |
| Map snapshot / overlay composition | RunPlayPlatform |
| Export configuration + card model | RunPlayCore |
| Distance/pace calculations | RunPlayCore |
| Route projection, segment detection | RunPlayCore |
| File I/O, manifest, persistence | RunPlayCore |

## Running the app for manual verification

This is a Swift Package — there is no `.xcodeproj`. Open in Xcode with:

```bash
open Package.swift
```

Then select the **RunPlayStudio** scheme and **My Mac** destination, and press
**⌘R**. Use this Xcode path for interactive GUI verification and debugging.

Alternatively, build a local `.app` bundle:

```bash
./scripts/package-demo.sh
# Output: .build/artifacts/RunPlayStudio.app
```

All manual GUI verification checklists are in `docs/manual-testing.md`.
