# Accessibility Audit — RunPlay Studio

This document describes the durable keyboard and accessibility contract.
Unchecked manual items are explicitly unverified; the live pull request and CI,
not this document, record transient head-specific results.

## Scope

Audited workflows:

- Launch and reopen the singleton main window
- Sidebar navigation (All Runs, Heatmap, smart collections, favourites, recent)
- All Runs search, filters, sort, selection, tags
- Workout tabs, replay, charts, splits/laps, segments
- Comparison and Personal Heatmap
- File import, Strava archive import, metadata editing, PNG and video export surfaces
- Alerts, confirmations, progress, empty states

## Command architecture

Focused scene values publish action bundles from the active workspace:

| Bundle | Source | Menu |
|--------|--------|------|
| `AppWorkspaceActions` | `ContentView` | File import, Library destinations |
| `ReplayActions` | `WorkoutDetailView` | Replay |
| `LibraryActions` | `WorkoutLibraryView` | Find, Edit Tags |
| `MapActions` | Map / Heatmap / Comparison map | Fit, 2D/3D |
| `AppPresentationActions` | `ContentView` | Help → Keyboard Shortcuts |
| `workoutTabSelection` | `WorkoutDetailView` | Workout tabs |

Authoritative inventory: `CommandRegistry` in
`RunPlayStudio/Sources/Commands/CommandRegistry.swift`.

NotificationCenter fallback remains only for All Runs / Heatmap workspace
commands when scene focus is cleared after reopening the main window.

## Final shortcut matrix

| Command | Shortcut | Workspace | Notes |
|---------|----------|-----------|-------|
| Import File… | ⌘I | Any | File menu |
| Import Strava Archive… | ⌘⇧I | Any | File menu |
| Overview | ⌘1 | Workout | Disabled without workout tab focus |
| Charts | ⌘2 | Workout | |
| Splits | ⌘3 | Workout | |
| Segments | ⌘4 | Workout | |
| All Runs | ⌘⇧L | Any | Notification fallback if unfocused |
| Personal Heatmap | ⌘⇧H | Any | Notification fallback if unfocused |
| Find in All Runs | ⌘F | All Runs | Focuses search field |
| Edit Tags… | ⌘⇧T | All Runs | Selection must include persisted workouts |
| Play/Pause | Space | Workout | System suppresses while text editing |
| Seek Backward 5 s | ⌥← | Workout | Clamped |
| Seek Forward 5 s | ⌥→ | Workout | Clamped |
| Slower | [ | Workout | Supported speed list only |
| Faster | ] | Workout | Supported speed list only |
| Restart | ⌘⇧← | Workout | Pauses at start |
| Fit Map | ⌘0 | Visible map | Route / routes / heatmap |
| Toggle 2D/3D | View menu | Visible map | No global chord; avoids the system Dock shortcut |
| Keyboard Shortcuts | ⌘/ | Any | Help sheet from registry |
| Open Selected Run | ↩ | All Runs table | Local; single selection only |
| Step frame ± | ← / → | Replay controls focused | Local only; not global menu |

## Shortcut-conflict analysis

- **⌘N / ⌘O / ⌘S / ⌘W / ⌘Q / ⌘,**: left to system/document defaults; not rebound.
- **⌘+/-**: not bound; MapKit zoom steppers own zoom.
- **Space**: menu command; macOS does not deliver it to the menu while a text
  field or text editor is first responder.
- **Bare arrows**: not global. Tables, lists, sliders, and text retain native
  behaviour. Frame step uses local shortcuts on replay buttons.
- **Escape / Delete**: not global. Escape clears All Runs search only when search
  is focused and nonempty. Delete deletes only one eligible selected persisted
  workout from the table context.
- **Toggle 2D/3D**: remains keyboard reachable through the native View menu.
  It intentionally has no global chord because ⌘⌥D belongs to the system Dock.

## Focus management

- All Runs search uses `@FocusState`; Command-F focuses it.
- Metadata editor focuses the name field and uses default/cancel actions.
- Sheets use `.keyboardShortcut(.defaultAction)` / `.cancelAction` where primary
  and dismiss actions exist.
- Strava archive and PNG export keep progress as a single status element without
  moving VoiceOver focus on every percentage tick.
- Descendant sheet/alert hosts publish
  `CommandBlockingPresentationPreferenceKey`; `ContentView` folds that into
  `sheetPresentationActive`. Background workspace shortcuts therefore disable
  for metadata, tag, collection, export, help, archive, importer, and error
  presentations.

## Replay keyboard behaviour

`ReplayController` / `PlaybackEngine` support:

- `seekBySeconds(_:)` with timeline clamping
- `slower()` / `faster()` over `speedOptions`
- `restart()` → stop at beginning, paused
- Replay commands disable when the selected workout has no playable GPS
  timeline.

Deliberate announcements: play, pause, restart, end reached, speed change.
Timer ticks never announce.

## Sidebar and All Runs

- Section destinations expose labels and selection via native list semantics.
- All Runs table columns expose concise values; missing device uses
  “unavailable” wording rather than a silent zero.
- Result count is near the heading (`resultSummary`).
- Tag chips combine into tag names; overflow uses the full tag list in the
  combined accessibility label.
- Mixed bulk-tag state speaks “Mixed”, not colour alone.

## Tags and smart collections

- Manage Tags / Create Tag / Smart Collection sheets keep cancel and default
  actions.
- Collection Modified badge has an explicit accessibility label.
- Organise menu is reachable without the pointer.

## Workout detail

- Header metrics use separate label/value/hint accessibility elements.
- Tab picker retains shortcut help in control help strings.
- Replay dock exposes timeline slider value, play state, speed, distance.
- Splits vs recorded laps remain distinguishable with mode accessibility labels.
- Segments expose type, range, value, selection, and seek action.

## Chart accessibility

- `ChartAccessibilityModel` builds summary text (range, average orientation,
  current value, gap count).
- `MetricChartDescriptor` implements `AXChartDescriptorRepresentable` with
  bounded, separately emitted continuous regions so audio graphs do not bridge
  recording gaps.
- Series aggregates and descriptor samples rebuild only when the selected
  metric or route data changes; replay ticks update only the current value.
- Keyboard seek: Jump to distance field, stepper, and VoiceOver custom actions
  “Seek earlier” / “Seek later” (±100 m).

## Map and heatmap summaries

- Route map accessibility value: distance, segments, start/finish, replay
  position, colour mode, coverage.
- Each workout, comparison, or heatmap map exposes its analytical summary once;
  decorative siblings and child map content do not duplicate the same long
  VoiceOver value.
- Metric legend already combines numeric ends and direction text.
- Comparison summary uses Primary P / Comparison C text identity; when
  Differentiate Without Colour is on, legend shows P/C symbols.
- Heatmap summary: included runs, distance, max overlap, cell sizes, date
  filter, minimum repeats. Cells are not individual VoiceOver elements.

## Comparison accessibility

- Legend, distance slider, and metrics row expose selected distance and deltas.
- Warnings retain symbol + text.
- End Comparison / Compare runs toolbar controls use clear spoken names.
- Comparison alignment picker announces Distance vs Route-Aware; Route-Aware
  summaries include quality, coverage, matched progress, mapped distances, and
  spatial separation without exposing individual DTW anchors.

## Import / export

- File and Strava import remain on File menu and empty states.
- Operation overlays expose combined accessibility labels.
- Archive sheet phases keep candidate table, progress, and report primary
  actions; cancellation and completion paths are keyboard reachable.
- PNG export preview remains one coherent accessibility description (existing
  view-model label tests).

## Dynamic announcement policy

Announce: library/import/export phase completions, heatmap ready, query result
publication (once per distinct count), comparison enter/exit, deliberate replay
state changes, and successful tag/collection updates. App-owned view models
share one retained, injectable `AccessibilityAnnouncementPolicy`.

Never announce: replay ticks, map camera motion, every progress percent,
per-keystroke search.

## Reduce Motion

- Map fit and pitch updates skip animation when Reduce Motion is enabled.
- Empty-state decorative animation already respects the environment.
- Replay content remains available; motion of the route marker is the product.

## Differentiate Without Colour

- Comparison legend shows P/C text markers under the system setting.
- Tag assignment uses checked / unchecked / mixed states with symbols and spoken
  values.
- Metric legends include numeric bounds and direction words.

## Increased Contrast and Reduce Transparency

- Controls use system semantic colours and `AppDesign` tokens.
- Map overlays use `.regularMaterial` / `.ultraThinMaterial` so Reduce
  Transparency hardens materials via the system rather than custom hardcoded
  fills.

## Automated tests

| Suite | Coverage |
|-------|----------|
| `CommandRegistryTests` | Uniqueness, preserved shortcuts, workspaces |
| `FocusedActionTests` | Replay/library/map action wiring, sheet gate |
| `ReplayControllerTests` | Seek by seconds, speed, restart |
| `AccessibilitySummaryTests` | Route/comparison/heatmap/chart models |
| `ChartAccessibilityTests` | Series, gaps, missing data |
| `MetricChartAccessibilityTests` | Bounded samples and separate gap series |
| `AccessibilityAnnouncementTests` | Policy, no tick spam |

## Automated verification commands

```bash
git diff --check origin/main
swift build -Xswiftc -warnings-as-errors
swift test --filter "CommandRegistryTests|FocusedActionTests|AccessibilitySummaryTests|ChartAccessibilityTests|MetricChartAccessibilityTests|AccessibilityAnnouncementTests|ReplayControllerTests" -Xswiftc -warnings-as-errors
```

Head-specific results belong in the live PR testing section.

## Keyboard-only verification

**Status:** Completed on the packaged app on 25 July 2026 using only synthetic
or repository-approved workouts. The pass covered:

- All Runs navigation, Command-F search focus, Escape clear, empty/single
  selection command availability, and Return opening the selected run.
- Command-1 through Command-4 workout tabs; Space play/pause; Option-Left/Right
  seek; restart; and speed changes through the keyboard-reachable Replay menu.
- Bare Right leaving replay unchanged at scene scope while retaining the
  timeline slider's native arrow adjustment when that slider owns focus.
- Help → Keyboard Shortcuts, including the menu-only 2D/3D entry and absence of
  the conflicting system Dock chord.
- Tag, Help, PNG, and video export sheets blocking background workspace commands.
- Workout, comparison, and heatmap map fit/presentation routing, including a
  visible camera transition and comparison enter/exit.
- PNG preview reaching Ready with one coherent labelled preview and keyboard
  cancel action.

Destructive deletion was not performed against the local library during this
pass. Eligibility, confirmation, and failure behavior remain covered by the
existing store, app-state, and library tests.

## Accessibility Inspector verification

**Status:** Completed on 25 July 2026 against the packaged app. The standard
macOS Accessibility Inspector audit completed with an empty warnings outline.
Direct hierarchy inspection confirmed bounded chart groups; labelled replay
controls; selection-aware disabled actions; and one analytical summary
container each for workout, comparison, and heatmap maps.

## Spoken VoiceOver verification status

**Status:** Completed to the environment's observable boundary on 25 July 2026.
macOS VoiceOver was started, the tutorial was dismissed, the caption panel
setting was confirmed enabled, and VoiceOver-modifier navigation was exercised
over the packaged app. The automation environment cannot record or transcribe
speaker audio, so spoken strings were cross-checked against the live VoiceOver
hierarchy and `AccessibilityAnnouncementTests`. VoiceOver and its tutorial were
stopped after the pass. Replay/progress tick suppression is also enforced by
the retained announcement policy tests rather than inferred from Inspector.

## Known limitations

- Map basemap remains primarily visual; summaries convey analytical meaning only
  (no reverse geocoding / place names).
- Heatmap cells are not individually accessible (by design).
- Focus return to the exact invoking control after every sheet is best-effort
  under SwiftUI.
- High-frequency metric readouts update values on focused controls without
  global announcements.

## Manual verification boundary

Automated tests prove models, command inventory, and controller semantics.
They do not replace Full Keyboard Access or spoken VoiceOver on the packaged
`.app`. Use synthetic or approved repository fixtures only.
