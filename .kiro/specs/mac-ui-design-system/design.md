# Design Document

## Overview

The redesign stays inside the existing three-layer dependency direction:

- `RunPlayCore` remains the platform-neutral source of workout data, formatting,
  replay state, comparison results, and importer errors.
- `RunPlayPlatform` remains the macOS adapter layer for AppKit, MapKit, SceneKit,
  and non-UI Combine services.
- `RunPlayStudio` owns `AppDesign`, SwiftUI composition, Charts, focus, native
  file panels, and user-facing copy.

The creative direction is documented in `DESIGN.md` as “The Cartographer's
Desk”: map-first, semantically colored, locally focused, and recognizably macOS.

## Components

### AppDesign

`DesignTokens.swift` is the single UI design-system source. It defines semantic
metric colors, an eight-step spacing scale, radii, Dynamic Type-aware typography,
native adaptive surfaces, `MetricDisplay`, `MapModeBadge`, and the shared panel
background modifier.

### Workout workspace

`WorkoutDetailView` remains the high-level composition root. Static header and
tab views are extracted from replay-dependent content. Overview, Charts, Splits,
and Segments occupy one main content region, with live metrics and replay controls
grouped in a bottom dock.

### Comparison workspace

`CompareView` composes a responsive selector, summary, shared route map, split
table, and pace chart. Blue identifies the selected route and orange identifies
the compared route. Comparison warnings remain visible in the map context.

### Accessibility and focus

The detail view publishes its tab binding through scene-focused values, and a
native Workout command menu owns Cmd+1 through Cmd+4. The shortcuts therefore
continue to work while the sidebar, map, or chart owns keyboard focus. Replay
play or pause uses Option-Space and frame stepping uses Option-arrow shortcuts,
so chart seek text remains editable. Chart dragging is supplemented by a
labeled numeric field and stepper; valid typed distances commit on submit or
when that field loses focus. Empty-state motion is disabled when Reduce Motion
is enabled.

### Performance

Chart samples are stored in view state and refreshed only for source changes.
Split highlighting resolves the active identifier once. `ReplayState` is
`Equatable`, and static workout header and tab content are isolated from direct
replay-controller observation.

## Native platform boundary

This work does not add an iOS product. `Package.swift` exposes Studio and
Platform only on macOS. AppKit color, font, save-panel, window, and image-rendering
APIs remain explicit in their owning modules; no parallel UIKit abstraction is
introduced.

## Verification strategy

- Warning-clean SwiftPM Core, Platform, and full-stack tests.
- Warning-clean Xcode workspace test for the `RunPlayStudio` scheme.
- `git diff --check` and CI status at the exact PR head.
- Packaged app launch plus fresh screenshots of Overview, Charts, Splits,
  Segments, and Compare with bundled or synthetic data.
- Live GitHub metadata and thread-aware review inspection before handoff.
