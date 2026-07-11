# Design Document

## Overview

Persistence is split across the existing three-layer architecture:

- `RunPlayCore` owns the versioned manifest, storage protocol, file-backed
  implementation, Codable snapshots, and platform-neutral tests.
- `RunPlayStudio` owns the default Application Support location, startup state
  application, import/delete interaction flow, alerts, and bundled resources.
- `RunPlayPlatform` remains unchanged because persistence requires neither
  MapKit/SceneKit services nor macOS value types.

## Storage layout

```text
~/Library/Application Support/RunPlayStudio/
  manifest.json
  workouts/
    <workout-uuid>.json
```

`Data.write(options: .atomic)` provides replacement-safe writes. Dates use
ISO-8601 encoding and decoding. Sorted JSON keys make persisted output stable
for diagnosis while manifest arrays retain the user's sidebar order.

## Components

### WorkoutLibraryStoring and FileWorkoutLibraryStore

The protocol exposes manifest and per-workout CRUD operations plus an existence
check. The file-backed implementation accepts an injected root URL so tests can
use isolated temporary directories. It contains no SwiftUI, AppKit, MapKit,
SceneKit, Charts, or CoreLocation imports.

### WorkoutLibraryStoreActor and WorkoutImportService

`WorkoutLibraryStoreActor` serializes manifest coordination, workout file I/O,
selection persistence, recovery, and transactional add/delete operations in
Core. `WorkoutImportService` is a separate actor that runs the synchronous
GPX/TCX/FIT/JSON parsers away from `@MainActor`. Both services are injectable
for Studio tests.

### AppState persistence coordination

`AppState` remains the UI state coordinator:

- Import saves the workout first, then updates the manifest, and removes the
  just-written workout if the manifest step fails.
- Selection updates the manifest and surfaces failures through the shared alert.
- Deletion commits the updated manifest before deleting the workout file. A
  manifest-write failure leaves UI state unchanged; a later file-delete failure
  leaves the workout logically deleted, updates UI state, and reports the
  orphaned file.
- Restored workouts use their stored `segments`; no duplicate segment analysis
  occurs on selection or startup.

### Bundled resources and UI

Bundled demos load through `Bundle.module`, independent of the current working
directory, and never enter the manifest. The existing native sidebar import and
destructive delete patterns remain in place. Delete confirmation explicitly
distinguishes the stored snapshot from the original imported file. Native
progress overlays communicate loading, importing, and deletion while the root
flow disables overlapping mutations.

## Recovery policy

- Missing manifest: normal first launch; show demos without an error.
- Corrupt/unsupported manifest: preserve it, show demos, and report the error.
- Missing/corrupt workout: skip it, load valid workouts, warn the user, and
  repair manifest references when the repair can be saved.
- Import manifest failure: delete the unreferenced newly written workout.
- Delete manifest failure: keep the stored workout and published UI unchanged.
- Delete file failure after manifest commit: keep the workout logically deleted
  and report the orphaned stored file.

## Verification strategy

- Core temporary-directory tests validate manifests, snapshots, atomic writes,
  corruption handling, schema versions, and complete model round trips.
- Studio tests exercise the async import entry point, relaunch restoration,
  background loading, selection failures, transactional deletion, demos,
  idempotent imports, cancellation, and comparison cleanup.
- SwiftPM, Xcode, Linux CI, packaged-app launch, and a manual desktop
  import/relaunch/delete/relaunch flow provide final integration evidence.
