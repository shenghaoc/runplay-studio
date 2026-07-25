# Requirements: Native Window and Application Session Restoration

## Problem

RunPlay Studio is a local macOS application, but its current SwiftUI
WindowGroup creates independent AppState instances and relaunching the app
forgets the user's workspace. The application should behave like one native
desktop document: native window management owns the main window while an
application-owned session restores the durable context that is useful after a
relaunch.

## Requirements

1. The application SHALL own one main native window with one shared AppState.
   Reopening the window through native commands SHALL reuse the same in-memory
   state and SHALL NOT create a second library coordinator.
2. Native window restoration SHALL remain enabled. Geometry, fullscreen,
   minimization, and placement SHALL be owned by SwiftUI/AppKit restoration;
   the application SHALL persist only sidebar visibility, not a manual column
   width or frame.
3. The first launch or a genuinely new window SHALL use a native default size
   near 1200 by 800 and a display-aware default placement. A restored native
   placement SHALL not be overwritten by application code.
4. The application SHALL persist a versioned, Codable, Equatable, Sendable
   AppSessionSnapshot separately from WorkoutLibraryManifest v3. The manifest
   remains authoritative for workout files, order, selected workout,
   favourites, tags, and smart collections; this feature SHALL NOT bump the
   manifest schema.
5. The session store SHALL be an injectable actor-backed file store at
   Application Support/RunPlayStudio/session.json. Writes SHALL be bounded,
   deterministic JSON, non-main-actor, and atomic replacement. Missing,
   corrupt, oversized, malformed, or future-version data SHALL fall back to a
   safe session without blocking startup.
6. Startup SHALL construct services, load and publish the library, apply the
   manifest-selected workout, load and validate the session, apply safe
   workspace/substate, and only then enable session writes. A restoration
   overlay SHALL prevent visible startup flicker.
7. The durable destination SHALL support the workout workspace, manual All
   Runs, a smart collection by UUID, Personal Heatmap, and a valid comparison.
   An invalid or missing destination reference SHALL fall back to the selected
   workout workspace or manual All Runs as appropriate.
8. The workout workspace SHALL persist the Overview/Charts/Splits/Segments
   tab, the 2D/3D route-map presentation, and replay position and speed.
   Replay persistence SHALL contain only workout UUID, elapsed seconds, and
   speed; replay SHALL always restore paused, with time clamped to the loaded
   route. Timer state, point-index authority, metrics, route points, and
   playback caches SHALL never be persisted.
9. All Runs SHALL persist the manual search, favourite/date/custom-range/source
   filters, data filters, tags filter, and sort. It SHALL persist smart
   collection identity plus Modified state and working query. It SHALL NOT
   persist result IDs, counts, table multiselection, tasks, documents,
   scroll position, or query caches. Missing collections SHALL fall back to
   manual All Runs while preserving the previous manual query.
10. Personal Heatmap SHALL persist date preset/custom bounds, resolution, and
    minimum workout count. It SHALL rebuild only when that destination is
    visible and SHALL not persist generated cells, map areas, cache, loading or
    error state, or camera/fit state.
11. Comparison SHALL persist only a valid distinct peer UUID and common-route
    distance. Invalid peers SHALL fall back to the workout workspace without an
    alert, and distance SHALL be clamped. Comparison SHALL never autoplay.
12. Transient sheets, alerts, import/archive/tag/collection/metadata/delete
    workflows, operation state, errors, progress, tasks, selections, and
    context menus SHALL never be restored.
13. A central validator SHALL enforce version, reference, finite-number, query,
    collection, tag, date, replay-speed, and size limits. Validation SHALL be
    deterministic and SHALL use lightweight library facts rather than route
    points or generated map data.
14. Restoration SHALL suppress writes until the application is active. Durable
    selection, import, delete, metadata, favourite, tag, collection, query,
    heatmap, comparison, and replay changes SHALL schedule bounded saves.
    Replay changes SHALL be coalesced to at most one write per second and
    flushed on pause, inactive/background, close, or termination.
15. The implementation SHALL preserve existing commands, including
    Command-1 through Command-4 tab selection, and SHALL add focused tests for
    snapshot coding, store behavior, validation, startup, workspace state,
    smart-collection semantics, heatmap filters, comparison repair, replay
    clamping/pausing, and native single-window behavior.

## Non-goals

- Persisting route points, map images, heatmap cells, table result membership,
  or any cloud/backend/account state.
- Replacing the v3 workout library manifest or introducing a third-party
  persistence framework.
- Persisting transient UI presentation, playback timers, selection
  highlights, task state, or arbitrary SwiftUI view state.
- Replacing native window geometry/restoration with a custom frame store.
