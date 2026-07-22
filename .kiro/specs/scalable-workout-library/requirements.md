# Requirements: Scalable Workout Library

## Problem

After importing a substantial local history (for example a Strava bulk export),
the sidebar renders the entire `[RunWorkout]` array. Users cannot search, filter,
sort, favourite, or edit name/notes without scanning an unbounded list.

## Requirements

1. The app SHALL provide an **All Runs** workspace (`AppWorkspaceMode.workoutLibrary`)
   that is mutually exclusive with workout, comparison, and Personal Heatmap.
2. Entering All Runs SHALL NOT clear `selectedWorkout`. Opening a result SHALL
   enter `.workout`. Deleting while All Runs is visible SHALL keep All Runs visible.
3. The sidebar SHALL stop rendering the unbounded Runs list. It SHALL show
   **All Runs** and **Personal Heatmap** under Library, plus bounded **Favourites**
   (cap 8), **Recent** (cap 10, non-favourites), and **Selected Run** when needed.
4. `RunPlayCore` SHALL provide lightweight `WorkoutLibraryEntry` rows that do not
   retain route-point arrays for query work, plus query/filter/sort models and a
   cancellable `WorkoutLibraryQuerying` service.
5. Search SHALL match only lightweight metadata (name, notes, activity, device,
   source, provider, original filename, date tokens). It SHALL NOT scan route
   points, GPS coordinates, raw FIT messages, export history, or absolute paths.
6. Search matching SHALL be case-, diacritic-, and width-insensitive; multi-term
   AND; quoted phrases where practical; empty query matches all.
7. Filters SHALL include favourites, date presets (including custom range),
   source (GPX/TCX/FIT/JSON), and data availability (HR, corrected elevation,
   recorded laps). Sort SHALL cover date, name, distance, active pace, elapsed,
   and library order with deterministic tie-breakers.
8. Manifest schema SHALL move to version 2 with `favoriteWorkoutIDs`. Version-1
   manifests SHALL decode with an empty favourite set without losing order or
   selection. Deletion SHALL remove favourites. No analysis/normalization bump.
9. Actor APIs SHALL support `setFavorite` and `updateWorkoutMetadata` with atomic
   persistence and no partial UI updates on failure.
10. Bundled demos SHALL NOT gain persistent favourites or pretend favourites
    survive relaunch.
11. Metadata name/notes editing SHALL use a central validation policy (limits,
    trim, empty → nil, reject NUL, no silent truncation of over-limit values).
12. Heavy filtering/sorting SHALL run off the main actor with cooperative
    cancellation and stale-result suppression. Personal Heatmap inputs SHALL NOT
    inherit All Runs filters.
13. All organisation remains local-only: in-memory search documents, no database,
    no cloud, no telemetry.

## Non-goals

Tags, folders, smart collections, saved searches, bulk edit/delete, SQLite /
SwiftData / Core Data, map/location search, reverse geocoding, AI search,
route editing, custom activity-type editing.
