# Requirements: Tags and Smart Collections

## Problem

All Runs supports search, filters, sort, and favourites, but users cannot
organise a large local library with reusable labels or save dynamic query
destinations. Organisation must remain local, JSON-manifest based, and must
reuse the existing query engine.

## Terminology

- **Tag**: user-created label assignable to zero or more workouts.
- **Smart Collection**: saved All Runs query (search, filters, tags, sort)
  whose membership is computed dynamically.
- **Manual All Runs Query**: ordinary search/filter/sort when not viewing a
  saved collection.
- **Modified Collection**: an open smart collection whose displayed query has
  been changed but not saved back.

## Requirements

1. `RunPlayCore` SHALL provide `WorkoutTag`, `WorkoutTagColor` (finite palette),
   `WorkoutTagAssignment`, and `WorkoutTagPolicy` with documented limits
   (200 tags/library, 50 name scalars, 20 tags/workout).
2. Tag names SHALL trim whitespace, reject empty/NUL/line breaks, preserve
   display casing, and be unique under case/diacritic/width-insensitive folding.
3. Tag definitions and assignments SHALL live in the library manifest only.
   Assigning tags MUST NOT rewrite workout snapshots.
4. Manifest schema SHALL become version 3 with ordered tags, assignments, and
   smart collections. Version-1 and version-2 manifests SHALL decode safely
   (missing fields → empty). Favourites, order, and selection SHALL be preserved.
5. Manifest repair SHALL remove dangling workout/tag assignment references,
   empty assignments, and invalid tag IDs in saved collection filters. When a
   collection loses all selected tags, the tag filter becomes no restriction;
   the collection is retained with a nonfatal warning when supported.
6. `WorkoutLibraryFilter` SHALL support tag match modes: any tags, untagged only,
   selected+any, selected+all. Empty selected sets behave as no tag restriction.
7. Free-text search SHALL match assigned tag names via search documents. Tag
   colors are not indexed. Route points are never scanned.
8. Actor APIs SHALL provide create/update/delete/reorder for tags; setTags and
   bulk updateTags for assignments; create/update/delete/reorder for smart
   collections. Each complete operation is one atomic manifest write.
9. Bulk tagging SHALL be all-or-nothing with one manifest write for the whole
   selection. Bulk deletion and bulk name/notes editing remain out of scope.
10. Deleting a workout SHALL remove its favourite and tag assignment atomically.
11. Deleting a tag SHALL remove assignments and clean saved-collection tag
    references atomically without deleting workouts or collections.
12. Smart collections SHALL persist `WorkoutLibrarySavedQuery` (no `now` or
    `Calendar`). Relative dates resolve when opened. Membership is never stored
    as workout IDs.
13. Selecting a smart collection applies its query atomically. Manual query
    state is session-only and restored when returning to ordinary All Runs.
    Filter edits mark the collection Modified; Revert restores; Update saves
    explicitly. Silent auto-update is forbidden.
14. UI SHALL provide tag chips, a Tags table column, single and bulk tag editors
    (tri-state bulk), Manage Tags, Save as Smart Collection, collection header
    with Modified/Revert/Update, sidebar Smart Collections (bounded cap), and
    Manage Collections. Creating a tag from an active tag editor SHALL dismiss
    that editor before presenting the create sheet; deleting a smart collection
    SHALL require confirmation; and requesting Manage Collections while another
    workspace is visible SHALL survive the transition to All Runs.
15. Favourites remain first-class (not a synthetic tag). Heatmap, comparison,
    and exports continue using the full library / existing export content.
16. Bundled demos cannot receive persistent tags. All organisation is local-only.

## Non-goals

Nested folders/collections, manual static collections, automatic/AI/location
tagging, reverse geocoding, cloud/shared collections, collection export/import,
bulk deletion, bulk metadata edit, SQLite/SwiftData/Core Data/iCloud, second
query engine, tag export in CSV/PNG/JSON summaries.
