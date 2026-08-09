# Design: Comparison Replay Video Export

## Ownership

```text
RunPlayStudio  → ComparisonVideoExportSheet / ViewModel, CompareView action
RunPlayPlatform → ComparisonVideoMapPreparation, pixel maps, frame renderer,
                  OfflineH264VideoAssetEncoder, ComparisonVideoExporter
RunPlayCore    → ComparisonVideoExportConfiguration, frame plan, sampler,
                 alignment resolver / seed, eligibility, filename
RunPlayEngineCpp → unchanged
```

## Shared encoder refactor

Extract `OfflineH264VideoAssetEncoder` from `WorkoutVideoAssetEncoder`:

- AVAssetWriter + H.264 High + BT.709
- Pixel-buffer pool (`kCVPixelFormatType_32BGRA`)
- Exact `CMTime(value: i, timescale: fps)`
- Writer backpressure, progress stride, finishWriting
- Media validation (tracks, dimensions, fps, frame count, duration, colour, decode)
- Temporary-file transaction + atomic publish

Frame provider contract:

```swift
protocol OfflineVideoFrameProviding: Sendable {
    var frameCount: Int { get }
    func renderFrame(at frameIndex: Int, into pixelBuffer: CVPixelBuffer) throws
}
```

`WorkoutVideoAssetEncoder` delegates to the shared writer. Comparison uses the
same writer with a comparison frame provider. No second AVAssetWriter stack.

## Core models

- `ComparisonVideoExportConfiguration` — duration, appearance, alignmentMode
- `ComparisonVideoDomain` — `.commonDistance` / `.alignedProgress`
- `ComparisonVideoFramePlan` — reuses overflow-safe frame-count arithmetic;
  domain position = progress × domainLength
- `ComparisonVideoFrameSample` — dual-workout metrics + optional separation/block
- `ComparisonVideoRoutePosition` — route point id/index/segment for pixel lookup
- `ComparisonVideoAlignmentSeed` — pair identity + revisions + snapshot
- `ComparisonVideoAlignmentResolver` — seed validation or one-shot DTW off main
- `ComparisonVideoExportEligibility` — Distance / Route-Aware assessments
- `ExportFilenameBuilder.comparisonVideoReplayFilename`

## Sampling

### Distance

`ComparisonVideoSampler` at each frame:

1. `domainPosition = plan.domainPosition(atFrameIndex:)`
2. `metricsAtDistance` with cached contexts
3. Resolve primary/comparison route positions via `RoutePointInterpolator.point`

### Route-Aware

1. `snapshot.positions(atAlignedProgress:)`
2. `RouteAlignmentMetricsService.metrics(atAlignedProgress:…)`
3. Map each side’s distance to route position for pixel lookup

## Map preparation

One MapKit snapshot for both segmented routes (primary blue, comparison orange).
No endpoint markers (or only P/C labelled endpoints). Capture every route-point
pixel per workout into gap-safe `ComparisonVideoRoutePixelMap` with distance
index for same-segment interpolation.

Wide geographic separation: still render; show HUD warning when relevant.

## Frame renderer

`ComparisonVideoFrameRenderer` draws into caller-owned BGRA buffers:

1. Static map
2. P marker (blue + P glyph) and C marker (orange + C glyph)
3. Header (names + vs + alignment)
4. Primary / Comparison / Delta panels
5. Progress bar (common distance or matched route)

Poster = midpoint frame via same renderer at half resolution.

## Export orchestration

`ComparisonVideoExporter`:

1. Eligibility + frame plan
2. Alignment resolution (seed or compute once)
3. Map preparation (or reuse)
4. Sampler construction
5. Shared H.264 encode
6. Validate + publish file-backed result

Never mutates AppState / ComparisonViewModel / live slider state.

## View model state machine

Structured phase: idle → preparingAlignment → alignmentUnavailable | loadingMap
→ posterReady → awaitingDestination → encoding → finalizing → completed |
cancelled | failed.

Reuse alignment when duration/appearance changes; rebuild map only when
appearance changes; reuse map when alignment changes; suppress stale posters.

Pair captured at sheet open is immutable for the export session.

## Accessibility

Dedicated announcement events for comparison-video preview ready, export
completed/failed/cancelled, and Route-Aware unavailable. Poster exposes one
combined summary. Progress throttled. Modal command blocking while sheet is
presented.

## Privacy

Local-only. MapKit may contact Apple for basemap. MP4 must not attach GPS,
UUIDs, paths, or library IDs as metadata. Two routes may reveal more location
history than a single-run export.

## Performance

Max 1,800 frames; no frame/pixel-buffer arrays; no MP4 `Data`; one map snapshot;
at most one DTW; two pixel indexes; serial writer; cooperative cancellation
during DTW, map, poster, encode, validate, publish.
