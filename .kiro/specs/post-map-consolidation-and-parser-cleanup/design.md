# Design Document

## Overview

`WorkoutDetailView` owns the selected tab and observes `ReplayController`.
Overview is deliberately a thin map-only child view. It receives the current
point index as a value so SwiftUI invalidates it whenever the observed parent
re-renders; it does not need a second observation of the controller.

The GPX and TCX XML parsers retain their per-parser cached ISO-8601 formatters.
The timestamp helper chooses the fractional formatter only when the timestamp
contains a fractional separator, otherwise it uses the standard formatter.

## Components

### WorkoutDetailView

- Defines only `overview` and `charts` detail tabs.
- Reads `replayController.state.currentPointIndex` while observing the replay
  controller and passes it to `OverviewView`.
- Continues to own the shared metrics, replay controls, and run summary so they
  appear once regardless of the selected tab.

### OverviewView

- Accepts `RunWorkout` and `currentPointIndex` as values.
- Renders `MapReferenceView` only.
- Has no nested `ObservableObject` subscriptions or duplicate controls.

### GPXImporter and TCXImporter

- Keep a fractional and standard `ISO8601DateFormatter` cache per parser.
- Select the fractional formatter for timestamps containing `.` and otherwise
  select the standard formatter.
- Preserve the standard formatter fallback for malformed fractional timestamps.

### Manual testing documentation

- Names Overview rather than the removed Map tab.
- Records the focused desktop smoke checks for the changed Overview, tab, replay,
  and native pitch-toggle flow; automated coverage remains documented separately.

## Verification Strategy

- GPX and TCX importer tests cover standard, fractional, and invalid timestamp
  inputs.
- The full SwiftPM test suite covers the macOS executable and the portable core.
- A desktop smoke session verifies the native map pitch toggle, Overview marker,
  current metrics, and Charts playback behavior.
