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

Modal hosts publish `CommandBlockingPresentationPreferenceKey`. `ContentView`
folds descendant sheets and alerts together with root import/archive/help
presentation into `sheetPresentationActive`, so workspace/replay menu items
disable while a modal workflow owns the window.

### Replay keyboard policy

- Global menu: Space, Option arrows (seek 5 s), brackets (speed), Command-Shift-Left (restart).
- Local only: bare Left/Right on focused step buttons.
- Text-system first responder continues to own Space and arrows when editing.
- Replay commands publish unavailable for workouts without a usable route
  timeline.

### Accessibility models (RunPlayCore)

Pure, testable text builders:

- `RouteAccessibilitySummary`
- `ComparisonAccessibilitySummary`
- `HeatmapAccessibilitySummary`
- `ChartAccessibilityModel`
- `TagSelectionAccessibilityState`

Studio views attach spoken summaries as accessibility labels/values and, for
charts, `AXChartDescriptor` via a value-type `MetricChartDescriptor`.
`MetricChartAccessibilityBuilder` retains gap boundaries and publishes each
continuous region as a separate accessibility series. Aggregate chart facts are
cached until route data or metric selection changes; replay ticks replace only
the current value.

### Announcements

App-owned view models share one retained, injectable
`AccessibilityAnnouncementPolicy`; export/replay views retain their local
policy. `AccessibilityAnnouncer` posts deliberate status updates only.
`shouldAnnounceReplayTick()` and
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
| View menu | Toggle 2D/3D | Keyboard reachable without rebinding the system ⌘⌥D Dock shortcut |

## Testing strategy

- Core: summary and chart model unit tests (Linux-safe).
- Studio: command registry uniqueness, focused action wiring, modal reduction,
  replay availability/seek/speed/restart, gap-preserving chart descriptors, and
  announcement integration.
- Manual: packaged `.app` keyboard-only and VoiceOver passes recorded in
  `docs/accessibility-audit.md`.
