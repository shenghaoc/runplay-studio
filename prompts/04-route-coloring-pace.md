# Prompt: Add 3D Route Coloring by Pace

## Context

RunPlay Studio's 3D route currently uses a single color. Adding pace-based coloring helps visualize speed variations throughout the run.

## Task

Implement pace-based coloring for the 3D route:

1. **Color strategy** - Create a `RouteColorStrategy` protocol:
   ```swift
   protocol RouteColorStrategy {
       func color(for point: RouteScenePoint, in range: ClosedRange<Double>) -> NSColor
   }
   ```

2. **Pace coloring** - Implement pace-to-color mapping:
   - Fast pace → blue/cyan
   - Average pace → green
   - Slow pace → yellow/red
   - Use perceptually uniform color scale

3. **Legend** - Add a color legend overlay showing pace range

4. **Gradient along route** - Apply smooth color gradient between points

5. **Toggle** - Add UI to switch between:
   - Solid color (current)
   - Pace coloring
   - Heart rate coloring
   - Elevation coloring

## Files to Create/Modify

- `RunPlayStudio/Sources/3D/RouteColorStrategy.swift` (create)
- `RunPlayStudio/Sources/3D/RouteSceneBuilder.swift`
- `RunPlayStudio/Sources/Views/Route3DReplayView.swift`

## Acceptance Criteria

- [ ] Route shows color gradient based on pace
- [ ] Color scale is perceptually uniform
- [ ] Legend displays pace range
- [ ] User can toggle coloring modes
- [ ] Performance remains smooth
