# Requirements: Workout Route Replay Video Export

## Problem

Runners can export JSON, CSV, and static PNG summary cards, but cannot export a
deterministic video of a completed workout’s route replay. Live screen capture
would couple output timing to UI state, machine speed, and display refresh rate.
Runners need a fixed-format, offline H.264 MP4 that compresses the full source
elapsed timeline into a short, shareable clip with a static map and moving
position marker.

## Requirements

1. Export Route Replay (MP4) SHALL open a configuration sheet with Video Length
   (15 / 30 / 60 s), Appearance (Light / Dark), Route Color (Solid / Pace /
   Heart Rate / Elevation), poster preview, Cancel, and Export Video.
2. Output SHALL be H.264 in an MP4 container at exactly 1920×1080, 30 fps,
   landscape, with no audio track and sRGB-compatible colour.
3. Video length presets SHALL be exactly 15, 30, and 60 seconds (default 30).
   Custom duration, frame rate, resolution, codec, bitrate, and aspect-ratio
   controls MUST NOT be offered.
4. Source timing SHALL map frame index `i` of `frameCount` frames to
   `sourceElapsed = (i / (frameCount - 1)) × totalElapsed` so frame 0 is source
   start and the final frame is source end with 100% progress. Timing MUST NOT
   depend on machine speed, live replay position, refresh rate, or window size.
5. Export SHALL use an independent replay sampler with the same canonical
   `PlaybackEngine` / `WorkoutTimeline` semantics. Live `ReplayController`
   state MUST NOT be mutated.
6. Video export requires a playable elapsed timeline, at least one usable GPS
   route coordinate, and positive finite total elapsed duration. Without these,
   the menu action SHALL be disabled with a concise explanation and the sheet
   MUST NOT open.
7. Map imagery SHALL come from one MapKit snapshot per map preparation
   (appearance / route colour). Duration-only changes MUST NOT re-request map
   imagery. Per-frame MapKit snapshots are forbidden. A basemap-free fallback
   is out of scope; map failure SHALL keep the sheet open with Retry and Cancel.
8. The static map SHALL include basemap, full segmented route (no gap bridging),
   and start/finish markers. The moving current-position marker is drawn per
   frame and MUST NOT jump across route-segment boundaries to invent continuity.
9. Frame HUD SHALL show workout title, date, elapsed, active, distance, active
   pace, heart rate and corrected elevation when available (else truthful
   placeholders), recording-gap / movement state when relevant, and progress
   (video progress plus source elapsed / total).
10. Encoding SHALL stream frames to a temporary file via AVAssetWriter with a
    pixel-buffer adaptor, validate the temporary asset, then atomically replace
    the user-chosen destination. The completed MP4 MUST NOT be loaded into
    `Data` / `ExportResult`. Cancellation and failure SHALL delete temporary
    output and leave no partial final file.
11. Rendering and encoding MUST NOT run on the main actor. Main actor may own UI
    state, save panel, throttled progress, and poster display only.
12. Accessibility: sheet controls labeled, poster as one summary element,
    progress without spam, deliberate announcements for preview ready / completed
    / failed / cancelled, background commands blocked while the sheet is open.

## Non-goals

- Screen/window/live-view capture, real-time replay recording, audio, microphone
- Custom duration/resolution/fps/codec, HEVC/ProRes/GIF/WebM
- Animated camera, 3D map video, multi-workout montage, heatmap video
- Mapless route-only fallback, cloud/AI rendering, telemetry, iOS
- New C++ engine kernels; do not change `VERSION` or release publication
