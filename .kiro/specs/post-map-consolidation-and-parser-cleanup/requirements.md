# Requirements Document

## Introduction

This maintenance change completes the post-MapKit consolidation work. It removes
duplicate detail controls and the duplicate map tab, preserves replay marker
updates, avoids an unnecessary failed ISO-8601 parse for standard GPX and TCX
timestamps, and keeps the operator documentation aligned with the shipped UI.

## Requirements

### Requirement 1: Single map detail surface

**User Story:** As a runner viewing a workout, I want one clear map landing
view so that I do not navigate between duplicate controls or duplicate map tabs.

#### Acceptance Criteria

1. WHEN a workout detail view opens, THEN Overview SHALL remain the default map
   landing view.
2. WHEN the detail tab picker is shown, THEN it SHALL offer Overview and Charts
   and SHALL NOT show a second Map tab that renders the same map.
3. WHEN a user views Overview, THEN shared current metrics, replay controls,
   and summary SHALL be provided once by `WorkoutDetailView`.

### Requirement 2: Replay marker updates

**User Story:** As a runner replaying a workout, I want the map marker to move
with playback so that the visible route state matches the selected metrics.

#### Acceptance Criteria

1. WHEN `ReplayController` updates its point index, THEN `WorkoutDetailView`
   SHALL pass the new index to Overview.
2. WHEN Overview receives a new point index, THEN it SHALL pass that index to
   `MapReferenceView` for the current route marker.

### Requirement 3: Timestamp parsing efficiency and correctness

**User Story:** As a runner importing GPX or TCX data, I want standard and
fractional ISO-8601 timestamps to import correctly without unnecessary parser
work.

#### Acceptance Criteria

1. WHEN a timestamp has no fractional seconds, THEN the importer SHALL use the
   standard ISO-8601 formatter without first attempting the fractional formatter.
2. WHEN a timestamp includes fractional seconds, THEN the importer SHALL accept
   it using the fractional ISO-8601 formatter.
3. WHEN no valid timestamps are supplied, THEN the importer SHALL reject the
   file with its existing missing-data error.

### Requirement 4: Accurate operator documentation

**User Story:** As a maintainer running manual checks, I want the checklist to
name the actual tabs and map surface so that it does not direct me to removed UI.

#### Acceptance Criteria

1. The manual checklist SHALL refer to the Overview map rather than a removed
   Map tab.
2. The manual checklist SHALL state that Overview and Charts are the detail
   tabs after consolidation.
