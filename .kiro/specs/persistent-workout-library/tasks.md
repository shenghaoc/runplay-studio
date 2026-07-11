# Implementation Tasks

- [x] Add the versioned manifest, storage protocol, and file-backed store in
  `RunPlayCore` with an injected root directory.
- [x] Persist complete normalized workouts with atomic writes and ISO-8601 dates.
- [x] Restore saved workouts, order, selection, replay state, and stored segments.
- [x] Keep bundled demos outside the user manifest and load them with
  `Bundle.module` rather than a working-directory fallback.
- [x] Make import persistence transactional and report cleanup failures.
- [x] Make persisted deletion rollback-safe and preserve UI state on failure.
- [x] Surface corrupt-library, selection-save, import-save, and delete errors.
- [x] Extract background loading from `AppState` into `WorkoutLibraryLoader`.
- [x] Clarify in the destructive confirmation that the original file is unchanged.
- [x] Add Core and Studio regression coverage for round trips and failure paths.
- [x] Update privacy and import documentation for persistent local snapshots.
- [x] Run the complete SwiftPM, Xcode, CI-equivalent, and packaged-app gates.
- [x] Complete and record the desktop import/relaunch/delete/relaunch flow.
- [x] Reconcile the final PR body, review threads, and GitHub checks.
