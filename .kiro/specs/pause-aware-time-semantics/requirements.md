# Requirements Document

## Introduction

RunPlay Studio must distinguish wall-clock elapsed time from recorded active
time whenever a route contains pause/resume or recording-gap boundaries. The
same semantics must drive analysis, replay, comparison, exports, persistence,
and user-facing labels. Moving-time threshold estimation is outside this spec.

## Requirements

### Requirement 1: Establish one time vocabulary and authority

**User Story:** As a runner, I want every screen and export to use the same
meaning for elapsed, active, and paused time so that my workout is not
misrepresented.

#### Acceptance Criteria

1. Elapsed time SHALL equal final route timestamp minus initial route timestamp
   and SHALL include pauses and recording gaps. When timestamps do not span but
   normalized points contain a valid elapsed series, that series SHALL provide
   elapsed time instead.
2. Active time SHALL sum only positive adjacent timestamp deltas whose points
   share a `routeSegmentIndex`. For the supplied-elapsed fallback, all elapsed
   time SHALL be active because pause boundaries cannot be inferred.
3. Paused time SHALL equal elapsed minus active and SHALL be finite and
   non-negative.
4. A platform-neutral `WorkoutTimeline` SHALL be the shared source of truth for
   analysis, splits, segment detection, replay, comparison, and exports.
5. Route-point `elapsedSeconds` SHALL remain elapsed time since workout start;
   active time SHALL be derived rather than persisted per point.
6. The product SHALL NOT label active time as moving time or estimate moving
   time in this change.

### Requirement 2: Publish explicit summary clocks and pace semantics

**User Story:** As a runner, I want summary pace to ignore pauses while still
being able to see the full elapsed cost of the workout.

#### Acceptance Criteria

1. `RunSummary` SHALL expose elapsed, active, and paused seconds.
2. The compatibility pace and speed fields SHALL use active time; additive
   elapsed pace and speed fields SHALL use elapsed time.
3. Empty, one-point, malformed, and no-pause routes SHALL produce safe finite
   non-negative results.
4. FIT selected-session elapsed/timer totals SHALL validate route-derived
   clocks and SHALL NOT blindly replace them.
5. A material FIT mismatch SHALL keep the route result and expose an import
   warning.

### Requirement 3: Migrate persisted analysis safely

**User Story:** As a runner with an existing library, I want old workouts to
gain correct clock semantics without losing their identity or disappearing.

#### Acceptance Criteria

1. Snapshots missing `analysisVersion` SHALL decode as legacy version `0`.
2. Library loading SHALL reanalyse stale snapshots from stored route points.
3. Migration SHALL preserve workout ID, metadata, source, route points, route
   segments, library order, and selection.
4. Upgraded snapshots SHALL be atomically persisted without a manifest schema
   bump.
5. A failed upgrade write SHALL leave the upgraded workout visible in memory,
   keep the legacy file retryable, and report a warning.

### Requirement 4: Keep kilometre splits global and gap-safe

**User Story:** As a runner, I want a kilometre interrupted by a pause to remain
one kilometre split with both clocks shown.

#### Acceptance Criteria

1. Split boundaries SHALL follow global cumulative distance and SHALL NOT
   restart at route-segment boundaries.
2. Only the final workout remainder SHALL be partial.
3. A split SHALL expose elapsed duration, active duration, active pace, and
   elapsed pace.
4. A duplicate-distance range start SHALL use the resumed point; a range end
   SHALL use the prior segment endpoint.
5. Time and samples MAY aggregate across segments, but geographic/elevation
   interpolation SHALL NOT cross a gap.
6. Heart-rate samples from all covered segments SHALL be included and
   elevation deltas SHALL remain segment-local.

### Requirement 5: Detect notable pace windows with active time

**User Story:** As a runner, I want a pause inside a kilometre not to create a
false slowest-running highlight.

#### Acceptance Criteria

1. Fastest and slowest distance windows SHALL use active duration and pace.
2. A window MAY span route-segment boundaries in cumulative distance.
3. Elevation and coordinate deltas SHALL remain segment-local.
4. No separate elapsed-fastest or elapsed-slowest segment type SHALL be added.

### Requirement 6: Replay the elapsed clock faithfully

**User Story:** As a runner replaying a paused workout, I want to see the stop
remain stopped until the recorded resume time.

#### Acceptance Criteria

1. Replay total duration SHALL equal summary elapsed time.
2. Replay lookup SHALL select the latest real point whose elapsed time is less
   than or equal to the current replay time.
3. During a gap, elapsed time SHALL advance while marker, distance, active time,
   and point metrics remain at the pre-pause endpoint.
4. At the exact resume timestamp, replay SHALL select the real resume point.
5. Stepping SHALL move only between real route points and remain safe for empty,
   one-point, and duplicate-time routes.
6. Selected metrics SHALL expose elapsed seconds, active seconds, and recording
   gap state.

### Requirement 7: Compare both clocks

**User Story:** As a runner comparing activities, I want pauses separated from
running performance.

#### Acceptance Criteria

1. Summary comparison SHALL expose elapsed, active, paused, active-pace, and
   optional elapsed-pace deltas.
2. Winner semantics SHALL use active pace.
3. Selected-distance comparison SHALL expose elapsed time, active time, active
   pace, and explicit deltas for each.
4. Workouts whose pause durations differ by at least the tested threshold SHALL
   receive an informative warning.

### Requirement 8: Export and label clocks explicitly

**User Story:** As a runner reading the UI or exported data, I want labels that
state which clock and pace they represent.

#### Acceptance Criteria

1. JSON, split CSV, segment CSV, and PNG summary output SHALL use explicit
   elapsed, active, paused, active-pace, and elapsed-pace names where relevant.
2. CSV values SHALL remain numeric, non-finite values SHALL be safe, and formula
   injection protection SHALL remain intact.
3. Summary, replay, split, comparison, segment, and export UI SHALL distinguish
   elapsed from active and explain that Pace uses active time.
4. UI changes SHALL remain focused and accessible rather than redesigning the
   product.

### Requirement 9: Verify the complete semantic contract

**User Story:** As a maintainer, I want automated and honest manual evidence
before the change merges.

#### Acceptance Criteria

1. Tests SHALL cover timeline edge cases, summary, global splits, active pace
   windows, replay gaps, comparison clocks, migration, FIT/JSON source policy,
   and explicit exports.
2. Warning-clean Core, full SwiftPM, Xcode package-scheme, and packaged-app
   launch gates SHALL be run.
3. Manual pause-flow checks SHALL remain unchecked unless actually completed.
4. The PR SHALL state that moving-time estimation remains unsupported.
