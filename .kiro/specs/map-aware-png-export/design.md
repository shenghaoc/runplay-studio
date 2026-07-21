# Design: Map-Aware PNG Summary Export

## Architecture

```
Export sheet (Studio)
  → PNGSummaryExportViewModel
      → route prep (Core profile + Platform map lines)
      → WorkoutMapSnapshotting (Platform / MapKit)
      → MapSnapshotOverlayComposer
      → ExportSummaryCardPresentation
      → PNGExportRenderer (fixed 1200×1600, scale 1)
      → NSSavePanel
```

Dependency direction stays `RunPlayStudio → RunPlayPlatform → RunPlayCore`.
MapKit and `NSImage` stay out of Core.

## Configuration

`PNGSummaryExportConfiguration` (Core): `includeMap`, `appearance` (light/dark),
`routeColorMode`. UI may offer System appearance only after resolving to Light
or Dark for the request. Defaults: include map when usable route exists;
appearance from resolved app appearance; route color from `@AppStorage` with
Solid fallback. Not stored on `RunWorkout`.

## Map snapshot

`WorkoutMapSnapshotting.makeSnapshot(request:)` in Platform:

1. `MapSnapshotRegionPlanner` pads route bounds, matches image aspect ratio,
   clamps world bounds, keeps short/single-point routes visible.
2. `MKMapSnapshotter` with standard 2D configuration, explicit size, Light/Dark
   `NSAppearance`. No pitched 3D camera.
3. `MapSnapshotOverlayComposer` draws basemap, converts coordinates via
   snapshot `point(for:)`, strokes each `RouteMapLine` separately (round caps/
   joins), draws start/finish only. Attribution area left unobstructed by
   card chrome/legend (outside map).

Cache is in-memory keyed by workout revision + mode + palette/planner versions
+ appearance + dimensions.

## Card presentation

Core `ExportSummaryCardModel` stays platform-neutral with layout-aware segment/
split limits and footer text. Studio `ExportSummaryCardPresentation` holds
`NSImage?`, legend model, appearance, and layout. Export palettes resolve every
color explicitly for Light and Dark.

## Concurrency

Snapshot + overlay + PNG encode off main actor where possible; `ImageRenderer`
on MainActor. View model cancels stale tasks via serial token; only newest
request publishes.

## Failure

Map errors preserve configuration, explain failure, offer Retry / Export
Without Map. Cancellation is silent.
