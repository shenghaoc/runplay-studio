# Requirements Document

## Introduction

RunPlay Studio needs a local workout library so imported runs survive process
relaunches without retaining a dependency on their original source files. The
library must remain local-only, preserve the platform-neutral Core boundary,
recover safely from partial corruption, and keep bundled demos separate from
user data.

## Requirements

### Requirement 1: Platform-neutral persisted library

**User Story:** As a runner, I want imported workouts stored locally so that I
can reopen RunPlay Studio without importing the same files again.

#### Acceptance Criteria

1. `RunPlayCore` SHALL provide an injectable workout-library storage protocol,
   a file-backed implementation, and a versioned manifest.
2. Each workout SHALL be stored as a complete normalized `RunWorkout` snapshot.
3. The manifest SHALL preserve workout order and the last selected workout ID.
4. Core persistence code SHALL import no Apple UI or platform-only framework.

### Requirement 2: Safe writes and recovery

**User Story:** As a runner, I want storage failures or damaged files handled
without silently erasing the rest of my library.

#### Acceptance Criteria

1. Workout and manifest writes SHALL be atomic or replacement-safe.
2. A manifest SHALL NOT reference a newly imported workout until its workout
   file has been written successfully.
3. If manifest persistence fails during import, the newly written workout file
   SHALL be removed or a cleanup failure SHALL be reported.
4. A corrupt manifest SHALL be preserved and reported without being overwritten
   during recovery.
5. A corrupt or missing individual workout SHALL be skipped while remaining
   valid workouts load, and the user SHALL receive a concise warning.
6. A manifest-write failure during deletion SHALL leave published UI state
   unchanged. If the manifest commits but file deletion fails, the workout
   SHALL remain logically deleted and the user SHALL receive an orphaned-file
   warning.

### Requirement 3: Startup, selection, and demos

**User Story:** As a returning runner, I want my saved library and selection
restored consistently while still seeing demos on a true first launch.

#### Acceptance Criteria

1. Production startup SHALL load and decode the library away from the main
   actor, then publish the resulting state on the main actor.
2. A valid saved selection SHALL load into `ReplayController` and restore the
   workout's persisted segments.
3. Bundled demos SHALL appear only when no valid user workouts are available
   and SHALL NOT become user-library entries automatically.
4. Bundled demo lookup SHALL use the SwiftPM resource bundle and SHALL NOT
   depend on the process working directory.
5. Selection persistence failures SHALL be reported instead of swallowed.
6. Selecting bundled demos when no manifest exists SHALL remain an intentional
   persistence no-op without showing an error.

### Requirement 4: Import and deletion user flow

**User Story:** As a runner managing my library, I want imports and deletions to
be truthful, persistent, and clear about what happens to my original files.

#### Acceptance Criteria

1. A parsed import SHALL update in-memory state only after its workout file and
   manifest entry are saved.
2. A successful import SHALL become the selected workout and survive relaunch.
3. Deleting a persisted workout SHALL remove its manifest entry and stored
   snapshot, update persisted selection, and clear affected comparison state.
4. The destructive confirmation SHALL state that only RunPlay Studio's stored
   copy is removed and the original imported file remains unchanged.
5. Deleting a workout SHALL remain deleted after relaunch.
6. Import, deletion, and startup SHALL expose native progress feedback and
   overlapping library mutations SHALL be disabled.

### Requirement 5: Local-only documentation and verification

**User Story:** As a maintainer, I want documentation and tests to describe the
actual persistence behavior and its verification limits accurately.

#### Acceptance Criteria

1. README and import documentation SHALL describe the Application Support
   location, snapshot behavior, deletion semantics, and unchanged privacy model.
2. Automated tests SHALL cover store round trips, corruption, missing files,
   import rollback, deletion rollback, selection persistence, and background
   startup loading.
3. Manual verification SHALL cover empty launch, import, relaunch restore,
   deletion, relaunch deletion persistence, and unchanged original source data.
