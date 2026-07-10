# RunPlay Studio Manual Testing

Manual checks supplement the SwiftPM test suite. Keep results concrete and avoid
committing local workout files or generated exports.

Current stabilization note: automated validation passed with `swift test`
(441+ tests) and `swift test --filter RunPlayCoreTests` (114 tests). Specific
manual GUI passes are documented per checklist below; not all GUI behaviors
have been manually verified.

## Privacy Checklist Before Commit

- [x] Keep private workout files untracked or ignored.
- [x] Run `git status --short`.
- [x] Run `git diff --cached --name-status` after staging.
- [x] Verify no personal GPX, TCX, FIT, JSON, screenshots, or private exports
  are staged.
- [x] Use explicit `git add <path>` rather than `git add -A`.
- [x] Keep committed fixtures and demo assets synthetic or anonymized.

Latest privacy notes:

- `activity_*.tcx` and `activity_*.fit` are ignored for local dogfooding.
- Real workout files should live under `local-workouts/` or
  `private-workouts/`.
- See `docs/private-data.md` for the durable private-data policy.

## Route Comparison Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs and, when available, a local user-provided TCX
  file. Do not commit private workout data.

Checklist:

- [x] App launches with at least two workouts loaded.
- [x] Existing 3D single-run replay renders before entering comparison.
- [x] Open Compare view from the toolbar.
- [x] Select a primary workout.
- [x] Select a comparison workout.
- [x] Verify the current primary workout is not offered as its own comparison.
- [x] Verify summary delta cards appear with pace in min/km.
- [x] Verify split comparison table headers show min/km units.
- [x] Verify pace-over-distance comparison chart appears with workout names in legend.
- [x] Verify chart axes show Distance (km) and min/km.
- [x] Verify chart subtitle says "lower is faster".
- [x] Verify 2D route overlay appears.
- [x] Verify primary/comparison legend appears.
- [x] Verify changing the primary selection clears comparison safely.
- [x] Import a local TCX through the visible Import control.
- [x] Compare the imported TCX with a bundled run and verify warnings appear for
  very different distances or route shapes.
- [x] Verify warnings show common distance when routes differ significantly.
- [x] Verify existing 3D single-run replay still works after comparison.
- [x] Verify export actions are still exposed.
- [x] Save at least one JSON, CSV, and PNG export in a normal desktop session.

## 3D Comparison Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs.

Checklist:

- [x] App launches without crash.
- [x] Open Compare view with primary and comparison workouts selected.
- [x] Toggle from 2D Map to 3D View using the segmented picker.
- [x] Verify primary route renders in blue.
- [x] Verify comparison route renders in orange.
- [x] Verify primary start/finish markers are labeled "P START" / "P FINISH".
- [x] Verify comparison start/finish markers are labeled "C START" / "C FINISH".
- [x] Verify both routes appear in the same 3D space with correct relative positioning.
- [x] Verify the 3D legend shows route names and colors.
- [x] Verify "Fit Routes" button frames both routes after the camera wiring fix.
- [x] Verify camera presets (default, top-down, side, front) work after the camera wiring fix.
- [x] Verify elevation scale controls (1x, 2x, 5x, 10x) rebuild the scene.
- [x] Verify grid toggle shows/hides the ground grid.
- [x] Verify warnings appear in the 3D view when applicable.
- [x] Toggle back to 2D Map and verify it still works.
- [x] Verify existing single-run 3D replay still works.
- [x] Verify 2D comparison still works.

Latest 3D comparison dogfood notes:

- App launched successfully from SwiftPM debug build.
- Both bundled demo runs loaded automatically.
- 3D comparison view renders both routes in the same scene.
- Primary (blue) and comparison (orange) routes are visually distinguishable.
- P START/P FINISH and C START/C FINISH markers appear.
- Legend shows route names and colors.
- Elevation scale controls rebuild the scene.
- Grid toggle shows/hides the ground grid.
- Segmented picker toggles between 2D and 3D views without crash.
- Camera-control wiring has been fixed in code and covered by
  `SceneCameraControllerTests`.
- Manual GUI pass on 2026-07-08 confirmed Fit Routes button frames both routes
  and camera presets (default, top-down, side, front) work correctly.
- Grid and kilometer-marker visibility toggles confirmed working.

## 3D Comparison Selected-Distance Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs.

Checklist:

- [x] App launches without crash.
- [x] Open Compare view with primary and comparison workouts selected.
- [x] Toggle to 3D View.
- [x] Verify distance slider appears at the bottom of the 3D comparison view.
- [x] Verify distance readout shows "0.00 km / X.XX km" format.
- [x] Move the slider and verify both "P X.XX km" and "C X.XX km" markers appear on the routes.
- [x] Verify markers move along the routes as the slider is scrubbed.
- [x] Verify elapsed time readout updates for both primary and comparison.
- [x] Verify time delta shows correct direction (faster/slower).
- [x] Verify pace readout updates for both primary and comparison.
- [x] Verify pace delta shows correct direction (faster/slower).
- [x] Test at start distance (0 km).
- [x] Test at midpoint distance.
- [x] Test at end distance (common max).
- [x] Verify backward-end button resets to 0.
- [x] Verify forward-end button jumps to common distance max.
- [x] Verify slider is disabled when routes are empty.
- [x] Verify existing camera presets still work after slider interaction.
- [x] Verify existing elevation scale controls still work.
- [x] Verify grid toggle still works.
- [x] Switch back to 2D Map and verify no crash.
- [x] Verify existing single-run 3D replay still works.

Latest 3D comparison selected-distance dogfood notes (2026-07-08):

- All items verified by human owner in a normal desktop session.
- Distance slider appears and shows "0.00 km / X.XX km" format.
- "P X.XX km" and "C X.XX km" markers appear and move along routes when scrubbed.
- Elapsed time and pace readouts update correctly with faster/slower direction.
- Backward-end and forward-end buttons work correctly.
- Camera presets, elevation scale, and grid toggle still work after slider interaction.
- Switching back to 2D Map does not crash.

## 3D Camera Controls Regression Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use bundled demo runs, or the explicitly provided local TCX file when
  dogfooding private data. Do not commit private workout data.

Checklist:

- [x] `SceneView` uses the controller-owned camera node as its point of view in
  single-run 3D replay.
- [x] `SceneView` uses the controller-owned camera node as its point of view in
  3D comparison.
- [x] Camera setup installs an active camera node in the SceneKit scene.
- [x] Fit-to-route math clamps non-finite and very large route extents.
- [x] Camera preset math leaves finite camera positions.
- [x] Comparison route bounds can drive camera fitting in unit tests.
- [x] Single-run 3D view loads an Apple Maps basemap aligned beneath the route.
- [x] Comparison 3D view loads one shared basemap aligned beneath both routes.
- [x] Grid toggle hides only the grid; the basemap remains visible.
- [x] Manually verify single-run Fit Route button in a normal desktop session.
- [x] Manually verify single-run camera presets in a normal desktop session.
- [x] Manually verify comparison Fit Routes button in a normal desktop session.
- [x] Manually verify comparison camera presets in a normal desktop session.
- [x] Manually verify manual orbit/zoom/pan still works after pressing presets.

Latest 3D camera-control dogfood notes:

- `swift build` passes.
- `swift test` passes with 433 tests, including focused
  `SceneCameraControllerTests`.
- Manual GUI pass on 2026-07-08 confirmed all camera controls work:
  - Single-run Fit Route button frames the route correctly.
  - Single-run camera presets (default, top-down, side, front) work.
  - Comparison Fit Routes button frames both routes correctly.
  - Comparison camera presets work.
  - Manual orbit/zoom/pan still works after pressing presets.

Latest 3D basemap dogfood notes (2026-07-10):

- Launched the SwiftPM GUI through `./script/build_and_run.sh --verify`.
- Confirmed the single-run 3D view renders Apple Maps streets, labels, parks,
  and waterfront context beneath the route.
- Confirmed hiding the adaptive grid leaves the basemap visible.
- Confirmed comparison 3D uses one shared basemap beneath both routes.

Latest dogfood notes:

- The bundled demo pair loaded on launch and produced summary deltas, split
  deltas, a pace chart, a 2D route overlay, and a legend.
- The comparison picker excluded the current primary workout.
- A local TCX imported successfully and produced a third run in the sidebar.
- Comparing the shorter TCX against a bundled run showed different-distance and
  different-route warnings and did not crash.
- Export menu actions were present, and save-panel export of JSON, CSV, and PNG
  confirmed working in manual GUI pass on 2026-07-08.

## Comparison Chart Readability Checklist

- [x] Comparison chart legend uses actual workout names (not "Primary"/"Comparison").
- [x] Chart y-axis shows min/km units.
- [x] Chart x-axis shows Distance (km).
- [x] Chart subtitle says "lower is faster".
- [x] Split comparison table headers show min/km units.
- [x] Proper empty states when comparison data is unavailable.
- [x] Warnings appear for different distances, insufficient overlap, missing data.

Latest comparison chart readability notes (2026-07-08):

- Manual GUI pass confirmed all chart readability improvements are working.
- Legend displays actual workout names.
- Axes and table headers show clear min/km units.
- Empty states and warnings display correctly.

## Export Smoke Checklist

Use bundled synthetic data for committed artifacts.

- [x] JSON summary export generated by `ExportServiceTests`.
- [x] Splits CSV export generated by `ExportServiceTests`.
- [x] Segments CSV export generated by `ExportServiceTests`.
- [x] Combined CSV export generated by `ExportServiceTests`.
- [x] PNG summary export generated by `ExportServiceTests`.
- [x] Synthetic demo PNG written to `docs/assets/demo-summary.png`.
- [x] Demo PNG opened and visually inspected.
- [x] Demo export text checked for private-data markers in tests.
- [x] Save-panel export of JSON, CSV, and PNG in a normal desktop session.

## Default View Checklist

- [x] On launch with sample data, user sees a map (Overview tab) as the default view
- [x] Map shows the route polyline with start/finish annotations
- [x] Summary metrics bar is visible below the map
- [x] Replay controls are accessible from the Overview tab
- [x] 3D Route tab still works when selected
- [x] Charts tab still works when selected
- [x] Map tab still works when selected

Latest default view notes (2026-07-08):

- All items verified by human owner in a normal desktop session.
- Overview tab is the default landing view with map and route overlay.
- Summary metrics and replay controls are accessible.
- All tabs (3D Route, Charts, Map) work when selected.

## Replay Visual Smoke Checklist

Automated coverage: `ReplayControllerTests` exercises `advancePlayback(by:)`,
end-of-route landing, speed multipliers, and marker-mapping fallback logic.
The following items still require manual GUI verification.

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the bundled sample run.

Checklist:

- [ ] **Overview tab playback**: press Play, yellow 2D marker advances along the route on the map.
- [ ] **Map tab playback**: switch to Map tab, press Play, yellow 2D marker advances.
- [ ] **3D Route tab playback**: switch to 3D Route tab, press Play, yellow 3D marker advances along the route.
- [ ] **Current metrics panel**: during playback, the metrics panel (distance, pace, HR) updates at each tick.
- [ ] **Charts tab**: switch to Charts tab, press Play, the current-distance indicator follows playback.
- [ ] **Step forward**: press step-forward button, marker advances one route point.
- [ ] **Step backward**: press step-backward button, marker moves back one route point.
- [ ] **Slider seek**: drag the chart distance slider, marker jumps to the seeked position.
- [ ] **End-of-route**: let playback run to completion; marker lands on the final route point and playback pauses.
- [ ] **Restart from end**: after playback reaches the end, press Play again; playback restarts from the beginning.
- [ ] **Speed change**: set speed to 4x, press Play, verify playback is visibly faster.
- [ ] **Pause stops animation**: press Play then Pause; marker stops advancing immediately.

## Delete UI Checklist

- [x] Right-click on a workout row shows "Delete Run" context menu
- [x] Selecting "Delete Run" shows a confirmation dialog
- [x] Confirming deletion removes the workout from the sidebar
- [x] Deleting the selected workout selects the next available
- [x] Deleting the comparison workout clears comparison mode
- [x] Deleting the last workout shows empty state
- [x] Keyboard delete (backspace) on selected workout works

Latest delete UI notes (2026-07-08):

- All items verified by human owner in a normal desktop session.
- Context menu, confirmation dialog, and deletion all work correctly.
- Comparison mode clears when the comparison workout is deleted.
- Empty state appears when the last workout is deleted.

## HR Color Mode Checklist

- [x] Heart Rate color button is disabled (grayed out) when route has no HR data
- [x] Heart Rate color button works normally when route has HR data
- [x] Tooltip explains why HR button is disabled

Latest HR color mode notes (2026-07-08):

- All items verified by human owner in a normal desktop session.
- HR button is correctly disabled when route has no HR data.
- HR button works normally when route has HR data.
- Tooltip explains the disabled state.

Latest export notes:

- Test-level export smoke coverage uses `RunPlayStudio/Resources/sample_run.json`
  and generated segments from that synthetic workout.
- The committed demo PNG is generated from bundled synthetic data only.
- Manual GUI pass on 2026-07-08 confirmed save-panel export works for JSON,
  CSV, and PNG in a normal desktop session.
