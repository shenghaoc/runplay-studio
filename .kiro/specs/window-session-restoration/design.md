# Design: Native Window and Application Session Restoration

## Ownership

The scene owns one stable logical Window with a title that remains
constant. RunPlayStudioApp owns the StateObject instances for AppState and
AppSessionController; ContentView receives them and never constructs
application state. The controller holds a weak AppState reference so the
application owns the lifecycle without a reference cycle.

SwiftUI/AppKit owns native window placement and restoration. The scene opts
into automatic restoration, supplies a display-aware default placement only
for new state, and binds sidebar visibility explicitly. No frame or sidebar
width is written to the application session.

## Session boundary

AppSessionSnapshot lives in Studio and contains only durable logical context:

- destination: workout, all runs, smart collection UUID, heatmap, or
  comparison;
- workout tab and map presentation;
- manual All Runs query, active collection identity, Modified state, and
  modified working query;
- heatmap filter selections;
- comparison peer UUID and distance;
- replay workout UUID, elapsed time, and speed;
- sidebar visibility.

WorkoutLibraryManifest v3 remains the source of truth for library membership,
order, selection, favourites, tags, and saved collection definitions. Session
state is applied only after the manifest load has selected the authoritative
workout.

## Persistence and validation

AppSessionStoring is an injectable Sendable protocol. FileAppSessionStore is an
actor that writes sorted-key JSON to session.json using a bounded atomic
replacement. It returns nil for missing or unusable data so startup can use a
safe default.

AppSessionValidator receives only IDs, collection/tag IDs, the selected
workout's duration, and comparison distance limits. It sanitizes enum-like raw
values, bounds oversized search text without discarding valid filters or sort,
repairs invalid dates, removes dangling tag references, clamps replay and
comparison numbers, rejects invalid comparison pairs, and falls back to the
selected workout/manual query when a destination cannot be restored.

## Startup and write lifecycle

AppSessionController coordinates this sequence:

1. await AppState library startup;
2. load the session actor off the main actor;
3. validate against the loaded library;
4. apply the snapshot to AppState and its workspace view models;
5. mark restoration active and schedule later durable writes.

The root view shows a restoration overlay until step 4 completes. Structural
changes are debounced; replay ticks are throttled and never write at 30 fps.
The controller flushes pending state before pausing for inactive/background
transitions. A narrow AppKit application-delegate adapter delays normal
termination until that flush completes. Import and deletion only schedule a
save after their manifest transaction has committed. Failed operations leave
the previous session untouched.

## View-model integration

AppState exposes the small raw-value bindings needed by the detail view and
sidebar. WorkoutLibraryViewModel converts its existing manual-query snapshot
to and from WorkoutLibrarySavedQuery and keeps Modified/Revert/Update
semantics. PersonalHeatmapViewModel applies only filter selections; the
visible heatmap view triggers the rebuild. ReplayController adds an explicit
restore operation that loads a workout, seeks a clamped time, applies a valid
speed, and pauses unconditionally.

Snapshot, store, and validator types do not import SwiftUI, MapKit, AppKit,
Combine, or route/map rendering types. AppKit is confined to the application
scene and its focused termination coordinator.
