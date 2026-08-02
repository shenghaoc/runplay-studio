# Tasks: Workout Route Replay Video Export

## Spec and preflight

- [x] Add `.kiro/specs/video-replay-export/{requirements,design,tasks}.md`
- [x] Branch `codex/video-replay-export` from latest `origin/main`
- [x] Confirm PR #99 / #100 in history; no open video-export overlap

## RunPlayCore

- [x] `WorkoutVideoDuration`, configuration, policy, phases, progress, errors
- [x] `WorkoutVideoFramePlan` (counts, source-time mapping, validation)
- [x] `WorkoutVideoReplaySampler` / frame sample models (independent of live replay)
- [x] Filename helper for `*-replay.mp4` without stuffing video into `ExportResult`
- [x] Core tests: frame plan, sampler (gaps, pauses, final frame, isolation)

## RunPlayPlatform

- [x] Map preparation protocol + MapKit preparer (pixel array, one snapshot)
- [x] Frame renderer (BGRA, static map + marker + HUD, Light/Dark)
- [x] Exporter (AVAssetWriter, temp file, validation, cancellation cleanup)
- [x] `WorkoutVideoExportResult` file-backed type
- [x] Platform tests with fake map preparer and tiny test policy

## RunPlayStudio

- [x] `WorkoutVideoExportViewModel` (poster, export, cancel, retry, serials)
- [x] `WorkoutVideoExportSheet` (presets, appearance, route colour, progress)
- [x] `ExportView` menu item + disabled no-route help + command blocking
- [x] Accessibility announcement events for video export
- [x] Studio tests: view model, eligibility, no live-replay mutation

## Documentation and validation

- [x] Update README, PRODUCT, DESIGN, architecture, privacy, manual-testing, a11y
- [x] Warning-clean Core/Platform/Studio suites and release packaging scripts
- [x] Draft PR with full description; do not merge
