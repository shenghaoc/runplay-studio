# Requirements Document

## Introduction

RunPlay Studio shall estimate moving and stopped time only within the existing
active clock. This is an additive GPS-derived estimate: it must not change the
meaning of elapsed, active, paused, or canonical active-time pace.

## Requirements

### Requirement 1: Preserve the four-clock contract

1. Elapsed SHALL include recording gaps; active SHALL exclude them; paused
   SHALL equal elapsed minus active.
2. Moving and stopped SHALL partition active time: `active = moving + stopped`.
3. All published values SHALL be finite and non-negative.
4. Labels and exports SHALL describe moving and stopped values as estimates.

### Requirement 2: Classify movement conservatively

1. A platform-neutral movement profile SHALL use normalized route points and
   `WorkoutTimeline` as its sole clock authority.
2. Thresholds, hysteresis, dwell periods, reliability, and cancellation stride
   SHALL reside in one policy type.
3. Explicit recording gaps SHALL remain paused, never stopped.
4. Slow or uncertain active intervals SHALL count as moving; sparse or
   irregular timing SHALL use the conservative active-as-moving fallback.

### Requirement 3: Reuse one analysis result throughout the product

1. Analysis contexts SHALL carry a movement profile for summaries, splits,
   replay, comparison, and exports.
2. Distance-based splits and comparison metrics SHALL interpolate movement and
   stopped clocks at partial continuous intervals while respecting timeline
   duplicate-distance boundary roles.
3. High-frequency comparison UI updates SHALL use cached contexts rather than
   recreating a profile for each scrub event.

### Requirement 4: Integrate safely and visibly

1. Summaries, splits, replay, comparison, JSON, CSV, and PNG output SHALL
   publish estimated moving/stopped information without relabelling active pace.
2. Persisted workouts SHALL gain diagnostics and a new analysis version while
   retaining backward-compatible decoding and reanalysis migration.
3. The UI SHALL use focused native macOS views, concise labels, help text, and
   VoiceOver labels for the new state information.

### Requirement 5: Verify the behavior

1. Tests SHALL cover stops, pauses, uncertain/fallback behavior, invariants,
   partial distance boundaries, comparison, persistence, and exports.
2. Warning-clean Core, full SwiftPM, Xcode package-scheme, packaging, and app
   launch verification SHALL be run before merge.
3. Manual stop/pause scenarios SHALL remain unchecked unless actually completed.
