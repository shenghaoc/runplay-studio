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
| `AppState` | Central `@MainActor @Observable` coordinator. Owns `workouts`, `selectedWorkout`, `replayController`, comparison state, and library operation state. |
| `ReplayController` | `@MainActor @Observable` wrapper around `PlaybackEngine`. Drives timeline, playback speed, and current route point. |
| `ContentView` | Root view. Hosts the sidebar and detail split. Owns the `.fileImporter` modifier and delegates import to `AppState`. |
| `WorkoutDetailView` | Detail host. Provides shared replay controls, metrics panel, and tab picker (Overview / Charts). |
| `OverviewView` | Default landing tab. Embeds `RouteMapCanvas` and passes the current point index from `ReplayController`. |
| `RouteMapCanvas` | Shared SwiftUI `Map` surface for both single-run and comparison maps. Owns `MapCameraPosition` and the 2D/3D pitch toggle. |
| `MetricsChartView` | Pace, elevation, HR, speed charts. Drag-to-seek pauses playback and updates `ReplayController`. |
| `CompareView` | Comparison host. Owns primary/comparison selection and delegates to `WorkoutComparisonService`. |

## Patterns

- Views read `AppState` and `ReplayController` via direct property access —
  no `@StateObject` or `@ObservedObject` (using Swift `@Observable`).
- Chart drag-to-seek: dragging any chart calls
  `replayController.seek(to:)` and sets `playbackState = .paused`.
- Map 2D/3D toggle: changes `MapCamera.pitch` on the shared `MapCameraPosition`
  — does not swap the map view or renderer.
- `RouteMapCanvas` is reused for single-run and comparison maps; do not create
  a second map type.
- PNG export uses `ImageRenderer` on a concrete SwiftUI view
  (`ExportSummaryCardView`) and requires a GUI context — do not call from tests.

## What belongs here vs. RunPlayCore

| Concern | Layer |
|---------|-------|
| SwiftUI views and modifiers | RunPlayStudio |
| `@MainActor` state, Combine publishers | RunPlayStudio |
| PNG rendering (`ImageRenderer`, `NSHostingView`) | RunPlayStudio |
| Distance/pace calculations | RunPlayCore |
| Route projection, segment detection | RunPlayCore |
| File I/O, manifest, persistence | RunPlayCore |

## Running the app for manual verification

This is a Swift Package — there is no `.xcodeproj`. Open in Xcode with:

```bash
open Package.swift
```

Then select the **RunPlayStudio** scheme and **My Mac** destination, and press
**⌘R**. Do not use `swift run` — the executable target requires macOS GUI
context that `swift run` does not provide.

Alternatively, build a local `.app` bundle:

```bash
./scripts/package-demo.sh
# Output: .build/artifacts/RunPlayStudio.app
```

All manual GUI verification checklists are in `docs/manual-testing.md`.
