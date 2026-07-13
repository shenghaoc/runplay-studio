# Requirements Document

## Introduction

RunPlay Studio needs a cohesive, native macOS presentation layer for workout
import, replay, analysis, comparison, and export. The redesign must improve
clarity and accessibility without changing the product into a cross-platform,
cloud-backed, or social fitness application.

## Requirements

### Requirement 1: Cohesive native design system

**User Story:** As a runner, I want the application to feel like one precise
macOS tool so that I can scan workout data without relearning each screen.

#### Acceptance Criteria

1. `RunPlayStudio` SHALL define semantic color, spacing, radius, typography,
   background, and reusable metric-display tokens in one focused source file.
2. Updated views SHALL use semantic tokens instead of introducing independent
   palettes or arbitrary spacing systems.
3. Metric values SHALL use monospaced digits where alignment aids comparison.
4. Root navigation, tables, toolbars, menus, alerts, and file panels SHALL use
   native macOS SwiftUI or AppKit patterns.
5. The package SHALL continue to advertise macOS, not unsupported iOS app
   availability.

### Requirement 2: Reachable workout analysis flow

**User Story:** As a runner, I want replay and analysis modes to remain obvious
and connected so that the redesign improves the real workflow rather than only
restyling isolated components.

#### Acceptance Criteria

1. The selected workout SHALL expose Overview, Charts, Splits, and Segments as
   first-class modes.
2. Replay controls and live metrics SHALL remain available with the selected
   workout and update from the real replay controller.
3. Comparison SHALL remain reachable from the toolbar and show the selected
   run, comparison run, summary deltas, warnings, routes, splits, and chart.
4. Import, destructive deletion, and export SHALL retain native dialogs and
   useful success or failure feedback.
5. Empty, loading, missing-GPS, missing-chart-data, and unavailable-comparison
   states SHALL explain the next useful action.

### Requirement 3: Keyboard and accessibility behavior

**User Story:** As a keyboard or assistive-technology user, I want the analysis
workflow to remain operable and understandable without pointer-only gestures.

#### Acceptance Criteria

1. Import, workout tabs, play or pause, and frame stepping SHALL have documented
   keyboard paths that do not override normal text-field navigation. Replay
   play or pause SHALL use Option-Space, and frame stepping SHALL use
   Option-arrow shortcuts.
2. Workout-tab shortcuts SHALL be registered as native window-wide commands so
   they keep working when the sidebar, map, or chart owns keyboard focus.
3. Interactive chart seeking SHALL provide a labeled text-field and stepper
   alternative to drag gestures, and a valid typed distance SHALL be committed
   both on submit and when the field loses focus.
4. The empty-state entrance SHALL honor Reduce Motion.
5. Destructive actions SHALL use a destructive role and explicit confirmation.

### Requirement 4: Playback and chart efficiency

**User Story:** As a runner reviewing a long route, I want playback and charts
to remain responsive as the current position changes.

#### Acceptance Criteria

1. Smoothed chart data SHALL be cached and recomputed only when its source data,
   selected metric, or smoothing window changes.
2. Split-row highlighting SHALL compare a precomputed active split identifier
   rather than scanning the split collection for every row.
3. The final split SHALL remain selected when replay reaches the exact workout
   end.
4. Fast replay-state updates SHALL not require static header and tab content to
   depend directly on the replay controller.
5. Metric chart scaling SHALL not force a zero baseline that visually flattens
   normal pace, heart-rate, speed, or elevation ranges.

### Requirement 5: Durable documentation and verification

**User Story:** As a maintainer, I want the design contract and PR evidence to
match the shipped implementation.

#### Acceptance Criteria

1. `DESIGN.md` and `PRODUCT.md` SHALL describe the final native macOS design
   direction without stale component claims.
2. SwiftPM and Xcode warning-clean tests SHALL pass without weakening coverage.
3. Manual verification SHALL cover the primary workout modes and comparison
   flow using synthetic or bundled data.
4. The PR title, body, testing commands, known risks, and review status SHALL
   match the exact final head.
