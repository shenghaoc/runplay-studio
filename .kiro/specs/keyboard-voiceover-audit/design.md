# Design: Keyboard Navigation and VoiceOver Accessibility

## Architecture

### Command registry

`CommandRegistry` in RunPlayStudio is the single inventory of menu and documented
local commands. `WorkoutViewCommands` binds handlers to registry-defined
shortcuts. `KeyboardShortcutsHelpView` lists `CommandRegistry.all`.

### Focused actions

| Bundle | Publisher | Consumers |
|--------|-----------|-----------|
| `AppWorkspaceActions` | `ContentView` | File import, All Runs, Heatmap |
| `ReplayActions` | `WorkoutDetailView` | Replay menu |
| `LibraryActions` | `WorkoutLibraryView` | Library menu (search, tags) |
| `MapActions` | Visible map views | View menu (fit, 2D/3D) |
| `AppPresentationActions` | `ContentView` | Help shortcuts sheet |
| `workoutTabSelection` | `WorkoutDetailView` | Workout tabs |

Sheet presentation sets `sheetPresentationActive` so workspace/replay menu items
disable while a modal workflow owns the window.

### Replay keyboard policy

- Global menu: Space, Option arrows (seek 5 s), brackets (speed), Command-Shift-Left (restart).
- Local only: bare Left/Right on focused step buttons.
- Text-system first responder continues to own Space and arrows when editing.

### Accessibility models (RunPlayCore)

Pure, testable text builders:

- `RouteAccessibilitySummary`
- `ComparisonAccessibilitySummary`
- `HeatmapAccessibilitySummary`
- `ChartAccessibilityModel`
- `TagSelectionAccessibilityState`

Studio views attach spoken summaries as accessibility labels/values and, for
charts, `AXChartDescriptor` via a value-type `MetricChartDescriptor`.

### Announcements

`AccessibilityAnnouncer` + `AccessibilityAnnouncementPolicy` post deliberate
status updates only. `shouldAnnounceReplayTick()` and
`shouldAnnounceProgressPercent()` are always false.

### Reduce Motion

`RouteMapCanvas` respects `accessibilityReduceMotion` for fit/pitch animation.
Existing empty-state and legend transitions already gate on Reduce Motion.

## Shortcut conflict analysis

| Shortcut | RunPlay Studio | macOS conflict notes |
|----------|----------------|----------------------|
| ⌘1–⌘4 | Workout tabs | Standard app section shortcuts |
| ⌘⇧L / ⌘⇧H | All Runs / Heatmap | App-specific |
| ⌘I / ⌘⇧I | Import file / archive | ⌘I is often Get Info; acceptable app override when app is frontmost |
| ⌘F | Library search | Standard Find when All Runs focused |
| Space | Play/Pause | Suppressed by system while text fields own first responder |
| ⌥← / ⌥→ | Seek ±5 s | Does not steal bare table arrows |
| [ / ] | Speed | Avoids ⌘+/- MapKit zoom |
| ⌘⇧← | Restart | Avoids bare ⌘← browser back patterns |
| ⌘0 | Fit map | Common “actual size” style; documented |
| ⌘⌥D | Toggle 2D/3D | Avoids Dock-hide ⌘⌥D only when app is key? On macOS Dock hide is system-wide; if conflict appears in practice, remap and document. Preferred safer alternative if needed: View menu without conflicting with Dock. |

**Dock hide note:** System ⌘⌥D toggles Dock. If packaging verification shows the
system shortcut wins or conflicts, change to a non-conflicting chord and update
the registry. Initial implementation uses ⌘⌥D as a discoverable View menu item;
document any live conflict in the audit.

## Testing strategy

- Core: summary and chart model unit tests (Linux-safe).
- Studio: command registry uniqueness, focused action wiring, replay seek/speed/restart, announcement policy.
- Manual: packaged `.app` keyboard-only and VoiceOver passes recorded in
  `docs/accessibility-audit.md`.
