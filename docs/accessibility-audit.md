# Accessibility Audit — RunPlay Studio

This document describes the **final tested application behaviour** on branch
`feat/keyboard-voiceover-audit`, not an aspirational checklist.

Last implementation head documented here: branch tip after keyboard/VoiceOver
work. Re-run automated commands at the final commit before merge; do not cite an
earlier green commit as final-head validation.

## Scope

Audited workflows:

- Launch and reopen the singleton main window
- Sidebar navigation (All Runs, Heatmap, smart collections, favourites, recent)
- All Runs search, filters, sort, selection, tags
- Workout tabs, replay, charts, splits/laps, segments
- Comparison and Personal Heatmap
- File import, Strava archive import, metadata editing, PNG export surfaces
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
| Toggle 2D/3D | ⌘⌥D | Visible map | See conflict note below |
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
- **⌘⌥D**: macOS also uses ⌘⌥D for Dock hide. If packaging verification shows
  a practical conflict, remap in `CommandRegistry` and this document. Prefer
  remapping over fighting a system chord.

## Focus management

- All Runs search uses `@FocusState`; Command-F focuses it.
- Metadata editor focuses the name field and uses default/cancel actions.
- Sheets use `.keyboardShortcut(.defaultAction)` / `.cancelAction` where primary
  and dismiss actions exist.
- Strava archive and PNG export keep progress as a single status element without
  moving VoiceOver focus on every percentage tick.
- Background workspace shortcuts disable while `sheetPresentationActive` is true
  for the archive importer and related presentation flags.

## Replay keyboard behaviour

`ReplayController` / `PlaybackEngine` support:

- `seekBySeconds(_:)` with timeline clamping
- `slower()` / `faster()` over `speedOptions`
- `restart()` → stop at beginning, paused

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
  downsampled series (bounded points, not one per GPS sample).
- Keyboard seek: Jump to distance field, stepper, and VoiceOver custom actions
  “Seek earlier” / “Seek later” (±100 m).

## Map and heatmap summaries

- Route map accessibility value: distance, segments, start/finish, replay
  position, colour mode, coverage.
- Metric legend already combines numeric ends and direction text.
- Comparison summary uses Primary P / Comparison C text identity; when
  Differentiate Without Colour is on, legend shows P/C symbols.
- Heatmap summary: included runs, distance, max overlap, cell sizes, date
  filter, minimum repeats. Cells are not individual VoiceOver elements.

## Comparison accessibility

- Legend, distance slider, and metrics row expose selected distance and deltas.
- Warnings retain symbol + text.
- End Comparison / Compare runs toolbar controls use clear spoken names.

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
state changes, tag/collection updates when wired.

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
| `AccessibilityAnnouncementTests` | Policy, no tick spam |

## Exact commands run (implementation verification)

```bash
git diff --check origin/main
swift build -Xswiftc -warnings-as-errors
swift test --filter "CommandRegistryTests|FocusedActionTests|AccessibilitySummaryTests|ChartAccessibilityTests|AccessibilityAnnouncementTests|ReplayControllerTests" -Xswiftc -warnings-as-errors
```

Full suite and packaged-app verification are recorded at PR final-head.

## Keyboard-only verification

**Status:** Implementation complete; full 34-step packaged-app keyboard-only
pass should be re-run on the final packaged `.app` before merge. Prior feature
areas (library Return/Delete, route colour menu, PNG sheet, archive sheet)
already had partial keyboard checks in `docs/manual-testing.md`.

## Accessibility Inspector verification

**Status:** Labels and values were designed against the hierarchy described
above. Final-head Inspector pass on the packaged app remains a pre-merge manual
gate.

## Spoken VoiceOver verification status

**Status:** Not claimed complete from Inspector alone. Spoken pass should be
recorded when the environment permits VoiceOver during packaging verification.

## Known limitations

- Map basemap remains primarily visual; summaries convey analytical meaning only
  (no reverse geocoding / place names).
- Heatmap cells are not individually accessible (by design).
- ⌘⌥D may conflict with system Dock hide; remap if observed.
- Focus return to the exact invoking control after every sheet is best-effort
  under SwiftUI.
- High-frequency metric readouts update values on focused controls without
  global announcements.

## Manual verification boundary

Automated tests prove models, command inventory, and controller semantics.
They do not replace Full Keyboard Access or spoken VoiceOver on the packaged
`.app`. Use synthetic or approved repository fixtures only.
