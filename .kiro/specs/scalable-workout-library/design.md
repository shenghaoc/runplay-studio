# Design: Scalable Workout Library

## Architecture

```
AppState (coordinator)
  ├── workspaceMode: .workout | .comparison | .personalHeatmap | .workoutLibrary
  ├── favoriteWorkoutIDs / hasPersistedLibrary
  └── workoutLibrary: WorkoutLibraryViewModel
        ├── entries + search documents (in memory)
        └── WorkoutLibraryQueryService (off main actor)
WorkoutLibraryStoreActor
  ├── setFavorite
  └── updateWorkoutMetadata
WorkoutLibraryManifest v2
  └── favoriteWorkoutIDs
```

## Workspace

`AppWorkspaceMode.workoutLibrary` drives `SidebarSelection.allRuns` and
`WorkoutLibraryView`. Selection of a workout from the sidebar or All Runs uses
existing `selectWorkout` / `openWorkoutFromLibrary` paths.

## Query pipeline

1. Build `WorkoutLibraryEntry` + `WorkoutLibrarySearchDocument` once per library revision.
2. On search/filter/sort change, cancel prior work and execute `WorkoutLibraryQueryService`.
3. Publish only if generation still current; keep last results visible while loading.

## Persistence

- Manifest v2 adds favourites; store accepts v1–v2, migrates on load/save.
- Metadata edits rewrite only the workout snapshot’s name/notes fields.
- Favourites never create demo manifest entries.

## Sidebar policy

`WorkoutLibrarySidebarPolicy.favoriteCap = 8`, `recentCap = 10`. Recent excludes
all favourites. Selected overflow is a one-row section. The favourites overflow
action clears prior All Runs search and non-favourite filters before showing the
complete favourites collection.
