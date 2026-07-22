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
2. `MKMapSnapshotter` with standard 2D configuration, explicit target size,
   and Light/Dark `NSAppearance`. No pitched 3D camera. macOS does not expose
   the iOS-only snapshot `scale` option, so the returned `NSImage` is normalized
   to the requested pixel dimensions before any overlay is composited.
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
on MainActor. Solid-color export bypasses metric-profile probing. Metric export
reuses the availability probe already prepared for the sheet instead of
building the same profile twice. The view model cancels stale tasks via serial
token; only the newest request publishes. Export stays disabled unless the
ready preview was generated for the current configuration.

The sheet is presented from the optional view-model item so SwiftUI never opens
the sheet before its model exists. Closing the sheet cancels active work.

## Failure

Map errors preserve configuration, explain failure, offer Retry / Export
Without Map. Cancellation is silent. A save-panel write failure preserves a
still-current ready preview so the user can retry another destination without
regenerating the image.
