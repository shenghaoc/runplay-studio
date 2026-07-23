# RunPlay Studio Manual Testing

Manual checks supplement the SwiftPM test suite. Keep results concrete and avoid
committing local workout files or generated exports.

Use the warning-clean SwiftPM and Xcode commands in `AGENTS.md` and live CI for
automated status. Dated manual GUI evidence is recorded with the relevant
checklist below; unchecked items have not been manually verified.

## Native Route Metric Coloring Checklist

Use only synthetic or approved repository fixtures. Do not claim scenarios that
were not performed. Metric modes are **relative to the selected workout** —
not personalized HR zones or grade-adjusted pace.

- [x] Launch a workout with pace, HR, and elevation data.
- [x] Confirm Solid is the default (or the persisted `@AppStorage` preference).
- [x] Switch to Pace; faster/slower sections are visibly distinct.
- [x] Confirm the legend shows relative pace within this workout with numeric ends.
- [x] Switch to Heart Rate; higher/lower areas appear; missing HR is neutral no-data.
- [x] Switch to Elevation; coloring follows corrected elevation, not raw spikes.
- [x] Toggle 2D and 3D in every mode; route remains consistent.
- [x] Replay the workout; the yellow marker stays responsive and is not recolored.
- [x] Switch color mode during playback; map does not blank; replay continues.
- [x] Open a workout without HR; Heart Rate is disabled or falls back with help.
- [x] Open a multi-segment workout; no line bridges a recording gap.
- [x] Open comparison; primary stays blue, comparison stays orange (no metric leak).
- [x] Open Personal Heatmap; density palette and controls are unchanged.
- [x] Inspect keyboard focus and VoiceOver labels on Route Color and legend.
- [x] Toggle light/dark appearance; metric colors remain legible over the basemap.
- [x] Quit/relaunch; route-color preference is restored.

Native route-coloring smoke record (2026-07-22): the packaged SwiftPM app was
launched with an isolated `CFFIXED_USER_HOME` and the bundled synthetic runs.
Solid, Pace, Heart Rate, and Elevation stayed fitted while switching between 2D
and 3D. Pace, HR, and elevation legends exposed relative numeric bounds. Replay
advanced to 0:16 while the current marker remained present, and switching from
Elevation to Pace did not stop playback or blank the map. Comparison retained
blue/orange identity and Personal Heatmap retained its density UI. A forced-light
test bundle and the normal dark appearance both kept the route and legend
legible. The selected mode survived workout changes and a packaged-app relaunch.
Importing the synthetic `realistic_5k_run.gpx` fixture exposed `Heart Rate —
Unavailable` with a coverage explanation. A temporary synthetic two-segment GPX
then showed 91% HR coverage with a neutral no-data span, no bridge across the
recording gap, and corrected elevation bounds of 12–24 m while the analysis
reported that a raw 900 m spike had been ignored. Accessibility inspection found
the labelled Route Color control and combined numeric legend; arrow-key/Return
operation selected a menu mode without pointer input.

## Personal Heatmap Checklist

Use only synthetic or explicitly private, ignored local workout files. Do not
commit screenshots of real home locations or personal heatmap exports.

- [ ] Launch with several GPS workouts in the library.
- [ ] Open **Personal Heatmap** from the Library sidebar section (or Workout → Personal Heatmap / ⌘⇧H).
- [ ] Confirm the map fits rendered heat cells on first appearance.
- [ ] Confirm repeated corridors look stronger than one-off paths.
- [ ] Confirm one dense-sampling workout does not overpower a sparse recording of the same path.
- [ ] Confirm route gaps do not draw a connecting hot corridor.
- [ ] Switch Fine (25 m) / Standard (50 m) / Broad (100 m); effective cell size label updates.
- [ ] Change minimum repeat count (1 / 2 / 3 / 5).
- [ ] Change All Time, Last 30 Days, Last 90 Days, This Year, and a custom range.
- [ ] Confirm an excluding date range shows the filter-empty state with All Time / Reset.
- [ ] Import a workout; library updates and heatmap recomputes when reopened or after filters refresh.
- [ ] Delete a workout while heatmap is visible; counts update and workspace stays on heatmap.
- [ ] Select a workout; normal workout workspace returns.
- [ ] Enter and leave comparison; heatmap and comparison never share the same workspace state.
- [ ] Verify keyboard shortcut and sidebar accessibility selection state.
- [ ] Inspect VoiceOver labels on legend, filters, and Fit Heatmap.
- [ ] Toggle light/dark appearance; heat fills remain legible.
- [ ] Resize the window; pan and zoom the map; use Fit Heatmap.
- [ ] Confirm single-route and comparison maps still render correctly.
- [ ] Relaunch: workout library persists; heatmap is recomputed (not stored as a second route DB).

## Route Quality Checklist

This checklist is intentionally unchecked. It defines the required GUI pass
and does not claim that any route-quality scenario has been manually verified.
Use only synthetic or explicitly private, ignored local workout files.

- [ ] Import a synthetic flat route containing altitude jitter.
- [ ] Confirm the flat route's elevation gain is small and believable.
- [ ] Confirm the elevation chart is visibly smoother while distance seeking
  remains aligned.
- [ ] Import a real-looking sustained climb and confirm the climb remains
  visible in the chart and analysis.
- [ ] Import a route containing one distant isolated coordinate spike.
- [ ] Confirm the map does not jump to or draw the rejected spike.
- [ ] Confirm total distance, derived speed, and pace do not include the
  rejected spike.
- [ ] Import a route containing a sustained coherent relocated cluster.
- [ ] Confirm the map shows disconnected route segments instead of a bridging
  line.
- [ ] Confirm replay jumps across the inferred gap without interpolating
  missing movement.
- [ ] Confirm summary, splits, notable climb/descent, comparison, chart, route
  colouring, and JSON/CSV/PNG exports agree on corrected elevation.
- [ ] Quit and relaunch; confirm corrected analysis, diagnostics, warnings, and
  normalization migration persist without repeatedly rewriting a current
  workout.
- [ ] Confirm GPX, TCX, FIT, JSON, replay, comparison, deletion, and export still
  work, and cancellation leaves no partially persisted import.

Packaged release smoke record (2026-07-14): the synthetic `sample-run` flow was
selected in the release bundle, the corrected elevation chart and accessible
metric controls were inspected, the native 2D/3D map toggle was exercised,
comparison with `realistic_5k_run` was entered and exited, and the JSON/CSV/PNG
Export menu actions were visible. The anomaly-specific route-quality scenarios
above remain unchecked.

## Pause-Aware Time Semantics Checklist

- [ ] Import or generate a workout with a visible pause.
- [ ] Confirm summary shows different Active and Elapsed durations.
- [ ] Confirm replay total equals Elapsed.
- [ ] Start replay and watch it enter the pause.
- [ ] Confirm the marker remains at the stop point until resume.
- [ ] Confirm distance and active time remain fixed while elapsed time advances.
- [ ] Confirm a kilometre split crossing the pause is still one kilometre split.
- [ ] Confirm split active pace excludes the pause.

## Recorded laps (FIT / TCX)

- [x] Import a TCX with two seamless manual/auto laps; map route stays continuous across the lap boundary.
- [ ] Confirm Active time does not lose time at a seamless lap boundary.
- [x] Open Splits and switch between Distance Splits and Recorded Laps.
- [ ] Confirm recorded lap trigger, distance, clocks, and pace; missing values show as unavailable.
- [x] Seek to each lap start; replay highlighting changes exactly at the next-lap start.
- [ ] Import a TCX with a pause as multiple Tracks; the true pause remains a route gap.
- [ ] Import a FIT with manual and auto-distance laps; triggers and source totals are retained.
- [ ] Export Recorded Laps CSV, combined CSV (with `# Recorded Laps`), and JSON; filenames distinguish laps from splits.
- [ ] Quit and relaunch; recorded laps persist. Open a legacy FIT/TCX snapshot and confirm no fabricated laps; reimport recovers them.
- [x] Compare two workouts with recorded laps (ordinal pairing only).
- [ ] Compare the paused run against an otherwise identical uninterrupted run.
- [ ] Confirm active and elapsed deltas are distinguished.
- [ ] Export JSON, CSV, and PNG and inspect the labels.
- [ ] Relaunch and confirm migrated analysis remains correct.
- [ ] Confirm GPX, TCX, FIT, map, charts, deletion, and persistence still work.

Recorded-lap manual record (2026-07-16): the packaged app imported a synthetic
two-lap TCX through the native open panel. The route remained continuous, the
Recorded Laps mode showed Manual and Distance triggers with distinct clocks and
paces, selecting lap 2 sought replay to 0:20 and changed the current-lap banner,
and comparison exposed ordinal pairing with a clear missing-laps state. Export,
FIT, multi-track pause, deletion, and legacy-snapshot checks remain unchecked
here. A packaged-app rebuild and relaunch retained the imported recorded laps.

## Moving/Stopped Estimate Checklist

These are required manual checks for this estimated GPS analysis; they are not
claims of completed verification.

- [x] Import a synthetic route with a 30-second stationary traffic-light stop.
- [x] Confirm Active exceeds Moving, Stopped equals Active minus Moving, and labels say estimated.
- [x] Replay through the stop: elapsed/active advance, moving holds, stopped advances, and state says Stopped.
- [x] Replay through an explicit recording pause: only elapsed advances and state says Paused.
- [x] Inspect a split containing the stop and verify active and moving pace are separately labelled.
- [x] Compare it with an otherwise identical uninterrupted run and inspect moving/stopped deltas and caveats.
- [x] Inspect JSON, CSV, and PNG exports for estimated moving/stopped labels and diagnostics.
- [x] Quit and relaunch to confirm the reanalysed snapshot persists without repeated migration.

Moving/stopped manual record (2026-07-15): the packaged app imported a synthetic
30-second traffic-light stop (elapsed/active 1:10, moving 0:40, stopped 0:30)
and showed the estimated labels. Replay showed `Stopped` while the moving clock
held; a synthetic explicit pause showed `Paused` while active, moving, and
stopped held. The split table exposed both active and estimated moving pace.
Comparison with an otherwise identical uninterrupted run showed `-0:30 less
moving`, `+0:30 more stopped`, and the estimate caveat. JSON, CSV, and PNG
exports were saved through the native panels and inspected for the estimated
fields. The packaged app was quit and relaunched; it loaded the reanalysed
snapshots without repeating migration.

## FIT Import Checklist

Use synthetic FIT fixtures only. These are manual checks to perform in a GUI
session; they are not claims of a completed manual pass.

- [ ] Import a compressed-timestamp FIT running activity and verify its route, duration, replay, and charts.
- [ ] Import a FIT activity with timer stop/start events and verify the map and replay do not bridge the paused gap.
- [ ] Import enhanced altitude/speed values and confirm they are not truncated.
- [ ] Confirm a non-running FIT activity and an ambiguous multi-running-session FIT file show clear import errors.
- [ ] Cancel a large FIT import and confirm it is neither displayed nor persisted after relaunch.

## All Runs Library Checklist

Use synthetic fixtures only. Do not claim unperformed GUI scenarios.

- [ ] Open **All Runs** from the Library sidebar (or Workout → All Runs / ⌘⇧L).
- [ ] Confirm the sidebar does not list every workout; Favourites / Recent are capped.
- [ ] Search by name, notes, year, source, and device.
- [ ] Exercise date, source, favourite, and data filters; Clear Filters / Clear Search.
- [ ] Exercise each sort mode; missing dates/pace sort after valid values.
- [ ] Favourite / unfavourite a persisted workout; confirm sidebar Favourites update.
- [ ] Open **All Favourites…** after applying other search/filters; confirm it shows the complete favourites collection.
- [ ] Confirm bundled demos cannot be favourited as persistent library entries.
- [ ] Edit name and notes; search finds the new notes; empty name restores fallback display.
- [ ] Quit and relaunch; favourites and metadata persist for library workouts.
- [ ] Import one file and a Strava archive; All Runs refreshes once after commit.
- [ ] Delete a favourite; manifest favourite set no longer contains it.
- [ ] Open comparison, heatmap, and PNG export; none inherit All Runs filters.
- [ ] Keyboard: select rows, Return to open, Delete with confirmation, focus search.

## Persistent Workout Library Checklist

Use a synthetic fixture and confirm the original fixture checksum before and
after the flow.

- [x] Launch with an empty user library and confirm bundled demos appear.
- [x] Import a synthetic TCX workout through the sidebar Import control.
- [x] Quit and relaunch; confirm the imported workout returns selected.
- [x] Confirm bundled demos are not inserted alongside the persisted library.
- [x] Confirm Overview, Charts, replay, and comparison remain reachable.
- [x] Delete the imported workout through the destructive confirmation.
- [x] Quit and relaunch; confirm the deleted workout remains deleted and demos
  return as the empty-library experience.
- [x] Confirm the original TCX fixture checksum is unchanged.
- [x] Capture the empty, imported/restored, and post-delete states for the final
  HIG/UX audit.

Persistence dogfood record (2026-07-11):

- The packaged SwiftPM app launched with the two bundled demos when the user
  manifest was empty.
- `sample-run.tcx` imported through the native file picker, survived relaunch as
  the sole selected workout, and remained usable in Overview, Charts, and replay.
- The native delete confirmation stated that only RunPlay Studio's stored copy
  would be deleted. After deletion and relaunch, the imported workout stayed
  deleted and the bundled demos returned.
- The bundled comparison flow remained reachable after the persistence cycle.
- The synthetic fixture SHA-256 remained
  `a7b2f86e58832d3316fd2aa0cf89c648fbf653267f7f45f808b46a101fe06dba`.
- Screenshots are retained outside the repository in the final-gate audit
  artifact directory `pr23-persistence-audit`.
## Privacy Checklist Before Commit

- [x] Keep private workout files untracked or ignored.
- [x] Run `git status --short`.
- [x] Run `git diff --cached --name-status` after staging.
- [x] Verify no personal GPX, TCX, FIT, JSON, screenshots, or private exports
  are staged.
- [x] Use explicit `git add <path>` rather than `git add -A`.
- [x] Keep committed fixtures and demo assets synthetic or anonymized.
- [x] Store private workout files under `local-workouts/` or `private-workouts/`.
- [x] Note: `activity_*.tcx` and `activity_*.fit` are gitignored for local dogfooding.
- [x] See `docs/private-data.md` for the durable private-data policy.

## Route Comparison Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs and, when available, a local user-provided TCX
  file. Do not commit private workout data.

Checklist:

- [x] App launches with at least two workouts loaded.
- [ ] Single-run map toggles between 2D and 3D before entering comparison.
- [x] Open Compare view from the toolbar.
- [x] Select a primary workout.
- [x] Select a comparison workout.
- [x] Verify the current primary workout is not offered as its own comparison.
- [ ] Verify summary delta cards distinguish Active Time, Elapsed Time, Paused,
  and Active Pace (min/km).
- [ ] Verify the split table title says "Split Active Pace (min/km)" and its
  Selected, Comparison, and delta columns remain readable.
- [ ] Verify the active-pace-over-distance comparison chart appears with
  workout names in the legend.
- [x] Verify chart axes show Distance (km) and min/km.
- [x] Verify chart subtitle says "lower is faster".
- [x] Verify 2D route overlay appears.
- [x] Verify primary/comparison legend appears.
- [x] Verify changing the primary selection clears comparison safely.
- [x] Import a local TCX through the visible Import control.
- [x] Compare the imported TCX with a bundled run and verify warnings appear for
  very different distances or route shapes.
- [x] Verify warnings show common distance when routes differ significantly.
- [ ] Verify the single-run map still toggles correctly after comparison.
- [x] Verify export actions are still exposed.
- [x] Save at least one JSON, CSV, and PNG export in a normal desktop session.

## Apple Maps 2D/3D Toggle Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs.

Checklist:

- [x] App launches without crash.
- [x] Open the single-run map and confirm only one map surface exists per view.
- [x] Use the in-map toggle to switch from top-down 2D to pitched 3D.
- [x] Confirm streets, labels, route, and annotations remain
  on the same map while toggling.
- [ ] Confirm pan, rotate, zoom, compass, scale, and zoom controls work.
- [ ] Confirm Fit Route reframes the route in both modes.
- [ ] Start replay and confirm the current-position marker moves in both modes.
- [x] Open Compare with both bundled runs and toggle that same map between 2D
  and 3D.
- [x] Confirm primary remains blue and comparison remains orange.
- [ ] Confirm comparison warnings remain visible when applicable.

Implementation checks:

- [x] The shipped surface is SwiftUI `Map`, not `SceneView`.
- [x] The shared map uses `MapStyle.Elevation.realistic`.
- [x] 2D uses a 0° camera pitch and 3D uses a pitched `MapCamera`.
- [x] One in-map 2D/3D button controls the shared `MapCameraPosition`.
- [x] Single-run and comparison maps reuse `RouteMapCanvas`.
- [x] The discarded snapshot-on-SceneKit-plane code is removed.

## Comparison Selected-Distance Dogfood Checklist

- [ ] Open Compare with primary and comparison workouts selected.
- [x] Verify distance slider appears at the bottom of the comparison map.
- [x] Verify distance readout shows "0.00 km / X.XX km" format.
- [x] Move the slider and verify both P and C markers appear on the routes.
- [x] Verify markers move along the routes as the slider is scrubbed.
- [ ] Verify elapsed time, active time, and active pace readouts update for both
  routes.
- [x] Test at a midpoint distance.
- [ ] Verify the slider is disabled when routes are empty.
- [x] Toggle pitch while the slider is active and confirm markers remain on the
  same routes.
- [ ] Confirm backward-end and forward-end buttons still work.

Comparison dogfood record (2026-07-08):

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
- [ ] Split comparison table title shows Active Pace and min/km units without
  truncation.
- [x] Proper empty states when comparison data is unavailable.
- [x] Warnings appear for different distances, insufficient overlap, missing data.

Comparison chart readability record (2026-07-08):

- This record predates the pause-aware labels in the current branch. The
  unchanged chart layout was verified then; the reset items above require a
  fresh GUI pass.
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
- [x] Native MapKit pitch toggle switches the Overview map between 2D and 3D
- [x] Charts tab still works when selected
- [x] Overview and Charts are the only detail tabs; no duplicate Map tab is shown

Default-view dogfood record:

- On 2026-07-08, a human owner verified the prior map, summary, replay, and
  Charts flow in a normal desktop session.
- On 2026-07-11, the bundled sample was launched from the SwiftPM app bundle:
  Overview and Charts were the only detail tabs, and the Overview map toggled
  between native 2D and 3D presentations.

## Replay Visual Smoke Checklist

Automated coverage: `ReplayControllerTests` exercises `advancePlayback(by:)`,
end-of-route landing, speed multipliers, and marker-mapping fallback logic.
The following items still require manual GUI verification.

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the bundled sample run.

Checklist:

- [x] **Overview tab playback**: press Play, yellow 2D marker advances along the route on the map.
- [x] **Pitch toggle during playback**: toggle the Overview map between 2D and 3D while
  playing; the same marker continues advancing on the same route.
- [x] **Current metrics panel**: during playback, the metrics panel (distance, pace, HR) updates at each tick.
- [x] **Charts tab**: switch to Charts tab, press Play, the current-distance indicator follows playback.
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

## Legacy SceneKit Controls

The former SceneKit-only pace/elevation/heart-rate coloring buttons are not part
of the unified MapKit surface. Do not describe them as current product controls.

Latest export notes:

- Test-level export smoke coverage uses `RunPlayStudio/Resources/sample_run.json`
  and generated segments from that synthetic workout.
- The committed demo PNG is generated from bundled synthetic data only.
- Manual GUI pass on 2026-07-08 confirmed save-panel export works for JSON,
  CSV, and PNG in a normal desktop session.


## Map-aware PNG summary export (synthetic)

Use **synthetic or bundled demo workouts only**. Do not commit private PNGs.

1. Open Export → **Export Summary Card (PNG)** and confirm the configuration sheet.
2. Generate Light and Dark **map-inclusive Solid** cards; reopen the PNG and confirm
   exact **1200×1600** pixels and start/finish markers (no replay marker).
3. Generate Pace, Heart Rate, and Elevation cards when available; compare legends
   with the live single-workout map.
4. Disable Include Map; confirm metrics-only export still works.
5. Use a no-GPS synthetic workout; Include Map should be unavailable/off.
6. Simulate offline/map failure if practical; use **Retry** and **Export Without Map**.
7. Change options rapidly; confirm the preview updates without stale content.
8. Cancel generation; confirm no error alert for cancellation.
9. Keyboard-navigate the sheet; inspect VoiceOver labels on controls and preview.
10. Confirm JSON/CSV export, comparison, and personal heatmap remain unchanged.

Automated coverage: `PNGExportRendererTests`, `PNGSummaryExportTests`,
`PNGSummaryExportViewModelTests`, `MapSnapshotRegionPlannerTests`,
`MapSnapshotOverlayComposerTests`.

Focused pre-merge smoke record (2026-07-22): the packaged app was launched with
an isolated temporary home and only bundled or generated synthetic workouts.
Light and Dark map-inclusive Solid cards, Pace, Heart Rate, Elevation,
metrics-only, and no-GPS cards were saved under `/private/tmp`, reopened, and
confirmed as distinct 1200×1600 PNGs. Start/finish markers appeared without a
replay marker, and Pace, Heart Rate, and Elevation legend values matched the
live map accessibility labels exactly. The no-GPS sheet disabled Include Map,
explained the metrics-only fallback, and exported successfully. Rapid option
changes settled on the latest configuration; Escape cancelled active preview
work without an alert; Return invoked the default Export PNG action; and the
accessibility tree exposed concise labels, help, status, and preview text.

A host-wide network disconnect was not used because there is no safe per-app
MapKit network fault switch. The same offline/map-failure state is exercised
deterministically by `PNGSummaryExportViewModelTests`, including Retry, Export
Without Map, stale-preview rejection, and save retry. Save-panel JSON and
combined CSV exports were reopened and inspected, and comparison and Personal
Heatmap were entered successfully after the PNG flow.

## Strava bulk archive import (synthetic)

Use a **synthetic** ZIP only — never commit real exports.

1. **Import Strava Archive…** → select synthetic ZIP.
2. Confirm review counts and candidate statuses.
3. Filter/search; Select All Importable / Select None; keyboard navigation.
4. Import mixed FIT/GPX/TCX/GZIP running activities.
5. Cancel a second large import; confirm no partial library additions.
6. Archive with one corrupt activity → valid siblings still import.
7. Import the same archive again → zero new workouts.
8. Completion report counts match expectations.
9. Open most recent imported workout; check laps/replay/charts.
10. Open Personal Heatmap → one recomputation with new history.
11. Quit and relaunch → workouts persist.
12. Delete one imported workout → heatmap updates.
13. Single-file import and comparison still work.
14. Light/dark, keyboard, VoiceOver labels on the archive sheet.

Focused pre-merge smoke record (2026-07-19): the packaged app exposed
**Import Strava Archive…** in both the File menu and native Import menu. A
temporary synthetic GPX archive scanned as one ready candidate, imported with
an `Imported: 1` completion report, and opened the resulting workout with its
route and replay. A repeat scan showed `1` duplicate, `0` ready/selected
candidates, and a disabled **Import 0 Runs** action; cancelling that review
returned to the workout cleanly. The imported run appeared in Personal Heatmap
(seven included runs) and remained selected after close/relaunch. The full
warning-clean suite covers cancellation rollback and library deletion. The
synthetic app-library record was then removed through the native delete
confirmation; the original ZIP remained untouched.
