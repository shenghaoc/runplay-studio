# Prompt: Add Chart Scrubbing and Sync

## Context

RunPlay Studio has charts for pace, elevation, and heart rate. These should sync with the 3D replay and allow scrubbing.

## Task

Implement interactive chart scrubbing:

1. **Hover sync** - When hovering over a chart, show corresponding position on:
   - 3D route (marker)
   - Map (marker)
   - Timeline slider

2. **Click to seek** - Clicking on chart seeks the replay to that point

3. **Drag scrub** - Dragging along chart scrubbing through the route

4. **Highlight region** - Show highlighted region on chart corresponding to current view

5. **Zoom** - Allow zooming into chart regions for detailed analysis

6. **Crosshair** - Show crosshair on chart at current replay position

## Files to Modify

- `RunPlayStudio/Sources/Views/MetricsChartView.swift`
- `RunPlayStudio/Sources/ViewModels/AppState.swift`
- `RunPlayStudio/Sources/Views/WorkoutDetailView.swift`

## Acceptance Criteria

- [ ] Hovering chart shows position on 3D/map
- [ ] Clicking chart seeks replay
- [ ] Chart and 3D stay in sync during playback
- [ ] Crosshair shows current position
- [ ] Zoom works smoothly
