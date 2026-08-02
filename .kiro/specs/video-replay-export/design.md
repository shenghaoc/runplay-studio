# Design: Workout Route Replay Video Export

## Ownership

```text
RunPlayStudio  → sheet, view model, NSSavePanel, a11y, ExportView
RunPlayPlatform → map prep, CG frame renderer, AVAssetWriter, file transaction
RunPlayCore    → duration/policy, frame plan, independent replay sampler, filename
RunPlayEngineCpp → unchanged
```

Dependency direction is preserved. AVFoundation and Core Video live only in
`RunPlayPlatform`. Core remains free of AppKit/MapKit/AVFoundation.

## Configuration and policy

- `WorkoutVideoDuration`: 15 / 30 / 60 seconds
- `WorkoutVideoExportConfiguration`: duration, appearance (`PNGSummaryExportAppearance`),
  route colour mode
- `WorkoutVideoExportPolicy`: 1920×1080, 30 fps, average bit rate, max 1 800 frames,
  progress update stride, policy version

All numeric limits are validated in the policy / frame plan; views do not hard-code
codec dimensions.

## Deterministic frame plan

```text
frameCount = durationSeconds × framesPerSecond   // 450 / 900 / 1800
progress(i) = i / (frameCount - 1)
sourceElapsed(i) = progress(i) × workoutTotalElapsed
```

Overflow-safe multiplication; require `frameCount >= 2` and finite positive total
elapsed.

## Independent replay sampling

`WorkoutVideoReplaySampler` loads the workout into a private `PlaybackEngine`
(or equivalent timeline + movement + elevation path) and seeks by source elapsed
time per planned frame. It never touches the app’s `ReplayController`.

Per sample: route point index, elapsed/active/moving/stopped, movement and
recording-gap state, distance, active pace, HR, corrected elevation, split and
recorded-lap indices when present.

## Map preparation

`WorkoutVideoMapPreparing` reuses region planning, route metric builders,
endpoint markers, image normalization, and overlay composition from the PNG
snapshot path.

Difference from PNG: while the live `MKMapSnapshotter.Snapshot` is available,
convert **every** route point to pixel coordinates, retain only
`WorkoutVideoRoutePixel?` (id, index, segment, point), and drop the MapKit
snapshot object. Result is `@unchecked Sendable` with a static `CGImage` plus
pixel array.

Invalid current marker: same-segment backward then forward pixel search; never
cross segment boundaries.

## Frame rendering

`WorkoutVideoFrameRenderer` draws into a caller-owned BGRA `CVPixelBuffer`:

1. Static map image
2. Moving yellow marker (when a same-segment pixel exists)
3. Header (title, date)
4. Metrics panel
5. State label
6. Progress bar + source elapsed text

Light/Dark palettes are fixed; no SwiftUI/`ImageRenderer` per frame. Poster
preview may use the same renderer at half resolution (960×540) or scaled
display.

## Encoding pipeline

`WorkoutVideoExporter`:

1. Validate eligibility and configuration
2. Prepare route presentation (once) + map (once for appearance/colour)
3. Create unique temporary MP4 (prefer destination volume)
4. `AVAssetWriter` + single video input (`expectsMediaDataInRealTime = false`)
5. Pixel-buffer adaptor pool (`kCVPixelFormatType_32BGRA`)
6. For each frame: sample → resolve marker → render → append at
   `CMTime(value: i, timescale: fps)` with readiness backpressure
7. Finish writer, validate asset (tracks, dimensions, duration, optional
   first/mid/last decode), move to destination
8. On cancel/fail: cancel writer, delete temporary file

Result type: `WorkoutVideoExportResult` (URL, filename, size, duration, frame
count, dimensions, fps) — not `ExportResult`.

## View model

`@MainActor` `WorkoutVideoExportViewModel` mirrors PNG export ownership:

- Configuration, availability probe, poster generation with request serials
- Duration change does not re-prepare map; appearance/colour does
- Export task with throttled progress; cancel restores controls
- Injectable map preparer and exporter for tests

## Privacy

Local-only. MapKit may contact Apple for basemap tiles (same as PNG). MP4 must
not attach GPS coordinates, library UUIDs, device serial, or absolute paths as
metadata. Visual route location is inherent to the basemap.

## Performance bounds

At most 1 800 frames; one static map; one profile prep; serial writer; no
full-frame arrays; no `Data` of the MP4; main actor never encodes.
