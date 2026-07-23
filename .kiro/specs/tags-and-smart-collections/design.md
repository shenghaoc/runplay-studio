# Design: Tags and Smart Collections

## Architecture

Dependency direction is unchanged: Studio → Platform → Core.

```
WorkoutLibraryManifest v3
  ├── tags: [WorkoutTag]
  ├── tagAssignments: [WorkoutTagAssignment]
  └── smartCollections: [WorkoutSmartCollection]
          └── query: WorkoutLibrarySavedQuery
                  ├── searchText
                  ├── filter (includes tag filter)
                  └── sort

WorkoutLibraryQueryService (existing)
  └── tag filter + tag-name search documents

WorkoutLibraryStoreActor
  └── tag / assignment / collection mutations (one save each)

WorkoutLibraryViewModel
  ├── query context: manual | smartCollection(id, isModified)
  ├── session manual-query snapshot
  └── multi-selection table state

SidebarView
  └── bounded Smart Collections section
```

## Persistence

- Tags and collections are ordered arrays (user reorder = array order).
- Assignments: one record per workout; empty omitted; tag IDs sorted for
  deterministic JSON.
- No membership lists, result counts, or workout snapshot rewrites.
- LoadResult carries organisation snapshot for UI publish after load/repair.

## Query

- `WorkoutLibraryTagFilter`: `.anyTags | .untaggedOnly | .selected(tagIDs, match)`.
- AND with favourites, date, source, data filters, and search terms.
- Search documents include ordered assigned tag names; rebuild only affected
  workouts on assignment/rename/delete.

## Smart collection UX

1. Save current All Runs query → create collection.
2. Sidebar open → apply saved query; stash manual query.
3. User edits → `isModified`; stored query unchanged until Update.
4. Revert → re-apply saved query.
5. Return to All Runs → restore manual snapshot.

## Isolation

Personal Heatmap, comparison availability, and exports ignore All Runs
collection/tag filter state unless a future product feature opts in.
