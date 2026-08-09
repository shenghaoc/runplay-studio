# Requirements: Comparison Replay Video Export

## Overview

Export the current two-workout comparison as a deterministic, local-only H.264
MP4. The video animates both workouts over the user-selected comparison domain
(Distance or Route-Aware) using an offline renderer — never screen capture or
live Compare-view recording.

## Media contract

| Property | Value |
| -------- | ----- |
| Container | MP4 |
| Codec | H.264 |
| Resolution | 1920 × 1080 |
| Frame rate | 30 fps |
| Audio | None |
| Colour metadata | BT.709 |
| Camera | Fixed top-down MapKit snapshot (one shot) |
| Lengths | 15, 30, or 60 seconds (default 30) |

Identical to the existing single-workout video contract. Do not introduce
additional resolutions, codecs, frame rates, or arbitrary durations.

## Configuration

Sheet controls only:

1. **Video Length** — 15 / 30 / 60 seconds
2. **Appearance** — Light / Dark
3. **Alignment** — Distance / Route-Aware

No route-colour modes. Identity is fixed:

- Primary = comparison blue (`0x0A84FF`) + `P` + primary name
- Comparison = comparison orange (`0xFF9F0A`) + `C` + comparison name

Configuration is sheet-local and is never persisted into app session state.

## Entry point

`Export Comparison Replay (MP4)…` appears only while a valid comparison pair
exists, in the comparison selector/header, via one shared component used by both
wide and compact Compare layouts.

Not in single-workout `ExportView`. No global command unless the focused-command
architecture already supports comparison-only enablement correctly.

## Eligibility

### Distance export

- Two different workouts
- At least one usable GPS coordinate in each workout
- Positive finite comparison common distance
- Valid analysis contexts

### Route-Aware export (additional)

- Available `RouteAlignmentSnapshot`
- Positive finite aligned distance
- At least one alignment block
- Matching ordered primary/comparison pair identity
- Compatible current alignment-policy version

Sheet may open when Distance is eligible. Route-Aware may load asynchronously.
When Route-Aware cannot be produced: keep Distance available, disable
Route-Aware, show structured reason, never silently label a Distance video as
Route-Aware.

## Video content

Each frame shows:

- One static top-down map with both complete routes (no gap bridging)
- Moving `P` and `C` markers
- Both workout names and alignment mode
- Comparison progress (common distance or matched route)
- Each workout’s mapped distance
- Elapsed and active clocks (matched clocks in Route-Aware)
- Active pace
- Elapsed, active, and pace deltas (text identity, not red/green alone)
- Current spatial separation in Route-Aware mode
- Alignment quality / limitations where relevant
- Block N of M when multiple alignment blocks exist

## Domain semantics

### Distance

```text
domainLength = min(primary total distance, comparison total distance)
distance(frame) = progress × common distance
```

Sample both workouts at that equal distance via existing
`WorkoutComparisonService.metricsAtDistance`.

### Route-Aware

```text
domainLength = RouteAlignmentSnapshot.totalAlignedDistanceMeters
```

Map aligned progress → `AlignedRoutePosition` → mapped distances →
`ComparisonAlignedMetrics`. Reuse snapshot; never re-run DTW per frame.

Matched clocks begin at the current block’s start anchor and must be labelled
`Matched Elapsed` / `Matched Active` / `Matched Pace`.

At block transitions markers may jump; clocks may reset; do not fabricate
connections between blocks.

## Timing independence

Rendering speed, comparison-slider position, window size, monitor scale, and
app foreground state must not affect output frame timing.

## Architecture

```text
RunPlayStudio  → sheet, view model, CompareView entry, a11y, save panel
RunPlayPlatform → combined map prep, pixel maps, frame renderer, shared H.264 writer
RunPlayCore    → config, frame plan, samplers, eligibility, alignment resolver
RunPlayEngineCpp → unchanged
```

Extract shared low-level H.264 writer from single-workout path. Preserve
single-workout visual, media, timing, cancellation, and file-transaction
contract with parity tests.

## Out of scope

Screen capture, live recording, audio, 3D camera, cloud/AI, custom duration or
resolution, metric colouring, Personal Heatmap video, new C++ kernels, release
publication.
