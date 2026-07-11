# Requirements Document

## Introduction

GPX and TCX files can contain discontinuous tracks caused by laps, pause/resume
events, or GPS dropouts. RunPlay Studio must preserve those boundaries from
import through analysis and rendering so it never invents travel, metrics, or
geometry across an absent section of a route.

## Requirements

### Requirement 1: Preserve source track structure

**User Story:** As a runner importing a GPX or TCX workout, I want independent
source tracks to remain independent so that gaps in the recording are not
presented as real movement.

#### Acceptance Criteria

1. WHEN a GPX file contains one or more `<trkseg>` elements, THEN each nonempty
   valid track segment SHALL receive a distinct route-segment index.
2. WHEN a GPX file contains waypoints or route points outside a track segment,
   THEN the importer SHALL ignore them.
3. WHEN a TCX activity contains multiple tracks or laps, THEN each valid track
   SHALL receive a distinct route-segment index.
4. WHEN a TCX file contains exactly one activity with valid GPS points, THEN
   the importer SHALL import that activity; WHEN multiple activities contain
   valid GPS points, THEN it SHALL reject the ambiguous file with an import
   error.
5. WHEN TCX distance values restart for a track, THEN that track SHALL be
   rebased without adding a geographic jump between tracks.

### Requirement 2: Keep route analysis segment-aware

**User Story:** As a runner reviewing a discontinuous workout, I want my
distance, pace, elevation, split, and highlight data to represent only recorded
movement.

#### Acceptance Criteria

1. The sanitizer SHALL not add geographic distance across a route boundary and
   SHALL keep cumulative distance monotonic across the imported workout.
2. The analyzer SHALL not derive speed, pace, elevation, or active elapsed time
   from a pair of points in different route segments.
3. Split calculation and notable-segment detection SHALL not create a time,
   pace, heart-rate, or elevation window that crosses a route boundary.
4. Interpolation and smoothing SHALL not blend values between route segments.

### Requirement 3: Render route gaps faithfully

**User Story:** As a runner viewing a route on a map or in the legacy 3D
utilities, I want gaps to remain visibly disconnected instead of being bridged
by a fabricated line.

#### Acceptance Criteria

1. Map rendering SHALL create a separate polyline for each route segment.
2. SceneKit route and highlight geometry SHALL not connect points with different
   route-segment indexes.
3. Existing start, finish, replay, comparison, and accessibility interactions
   SHALL remain available without adding a new user-facing control.

### Requirement 4: Preserve persisted workout compatibility

**User Story:** As a runner with an existing local library, I want older saved
workouts to continue loading after route-structure support is added.

#### Acceptance Criteria

1. `RoutePoint` SHALL persist `routeSegmentIndex` with every new workout.
2. WHEN a saved `RoutePoint` omits `routeSegmentIndex`, THEN decoding SHALL
   default it to `0`.

### Requirement 5: Verification

**User Story:** As a maintainer, I want automated and app-level evidence that
segment handling is correct before the change merges.

#### Acceptance Criteria

1. Automated tests SHALL cover multi-segment GPX and TCX imports, gap-safe
analytics, persistence compatibility, and gap-safe 3D highlight geometry.
2. The full SwiftPM and Xcode macOS test suites SHALL pass.
3. The packaged macOS app SHALL launch successfully after the change.
