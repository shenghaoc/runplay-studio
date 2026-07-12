# Requirements Document

## Introduction

RunPlay Studio must import common FIT running activity files without treating
valid compressed records, timer pauses, or session metadata as corruption. The
implementation remains an independently written, platform-neutral `RunPlayCore`
feature; it is not a complete FIT SDK implementation.

## Requirements

### Requirement 1: Decode supported FIT messages safely

**User Story:** As a runner importing a FIT activity, I want the app to retain
the data needed to interpret my route and metadata without desynchronizing on
unknown fields.

#### Acceptance Criteria

1. The parser SHALL decode file-ID, record, event, lap, session, activity, and
   device-info messages into Core-owned `Sendable` values.
2. The decoded file SHALL retain supported messages in original source order.
3. Unknown standard fields and developer fields SHALL consume their declared
   payloads safely without becoming application metrics.
4. Field constants SHALL be isolated and documented against Garmin FIT SDK
   Profile 21.205.0.

### Requirement 2: Support compressed timestamps and resilient binary input

**User Story:** As a runner with a normal device-generated FIT file, I want
valid compressed records to import and malformed input to fail clearly.

#### Acceptance Criteria

1. The parser SHALL reconstruct compressed timestamps only from a valid prior
   timestamp and SHALL handle the five-bit wrap window.
2. A compressed definition SHALL require a leading uint32 timestamp field; an
   absent baseline, missing definition, malformed header, or truncated payload
   SHALL return a protocol error.
3. Header and file CRCs, architecture bytes, reserved definition/header bits,
   field sizes, and data boundaries SHALL be validated.
4. The parser SHALL bound file size, definitions, developer fields, and decoded
   messages, and SHALL cooperate with cancellation every 1,000 messages.

### Requirement 3: Interpret one unambiguous running session

**User Story:** As a runner, I want an imported workout to use the FIT running
session rather than unrelated cycling, hiking, or multisport data in the file.

#### Acceptance Criteria

1. With exactly one GPS-bearing running session, the importer SHALL select it.
2. Multiple GPS-bearing running sessions SHALL fail as ambiguous; an explicitly
   non-running-only activity SHALL fail with an actionable import error.
3. Records and timer events outside the selected session SHALL not be imported.
   A missing start time may be derived from the profile-scaled elapsed duration;
   otherwise a multi-session file SHALL fail rather than merge data.
4. When session metadata is absent, a usable GPS stream SHALL retain the
   documented legacy single-activity fallback.

### Requirement 4: Preserve pause and distance fidelity

**User Story:** As a runner reviewing a paused activity, I want the map,
replay, distance, and analysis to show only recorded movement.

#### Acceptance Criteria

1. Timer start/stop boundaries SHALL assign separate route-segment indexes and
   SHALL not create phantom segments for duplicate events.
2. Paused records SHALL not become route points, and no geographic distance or
   analysis calculation SHALL bridge a segment boundary.
3. Complete monotonic supplied FIT distance SHALL be rebased per segment.
   Segments with missing or invalid supplied distance SHALL be computed from
   coordinates without decreasing cumulative workout distance.
4. Elapsed timestamps SHALL remain elapsed time; the feature SHALL not relabel
   timer/moving time as elapsed duration.

### Requirement 5: Verification and user flow

**User Story:** As a maintainer, I want evidence that FIT imports remain wired
through the existing native import workflow.

#### Acceptance Criteria

1. Parser and importer tests SHALL cover compressed timestamps, message
   mappings, sessions, timer segments, distance fallback, CRC failures,
   cancellation, and resource limits using repository-owned synthetic data.
2. The existing SwiftUI file importer SHALL continue dispatching `.fit` files
   through `WorkoutImportService` and `WorkoutImporterFactory` to `FITImporter`.
3. The warning-clean SwiftPM, Xcode macOS, and packaged-app launch gates SHALL
   pass before merge.
