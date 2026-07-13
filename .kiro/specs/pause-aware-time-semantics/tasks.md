# Implementation Tasks

- [x] Add `WorkoutTimeline` as the shared elapsed/active/paused, distance, and
  replay semantic authority.
- [x] Add explicit summary/split fields, Codable compatibility, analysis
  versioning, typed FIT warnings, and non-finite formatting safety.
- [x] Reanalyse stale library snapshots atomically while preserving identity,
  route structure, order, selection, and visibility on write failure.
- [x] Make global-distance splits and notable pace windows pause-aware without
  crossing gaps for coordinate or elevation deltas.
- [x] Keep replay on elapsed time with held gap state, exact-resume lookup,
  deterministic real-point stepping, and dual-clock selected metrics.
- [x] Publish elapsed/active/paused comparison semantics, both selected-distance
  clocks, active pace, and pause-duration warnings.
- [x] Make JSON/CSV/PNG output and SwiftUI labels explicit and accessible.
- [x] Sync the data model, architecture, import, README, demo, and manual-check
  documentation while leaving new manual pause checks unchecked.
- [x] Add focused timeline, analyzer, split, segment, replay, comparison,
  migration, FIT/JSON, and export regression tests and run the full SwiftPM
  suite warning-clean.
- [x] Run `swift package describe`, final Core/full warning-clean gates, Xcode
  package-scheme tests, and packaged-app launch verification.
- [x] Reconcile the final diff, publish a reviewable commit series, push the
  branch, and maintain a reviewable PR with exact validation and honest manual
  status.
