# Prompt: Improve 3D Route Geometry

## Context

RunPlay Studio uses SceneKit to render 3D routes. The current implementation uses cylinders between points, which can look jagged with sparse data.

## Task

Improve the 3D route rendering in `RunPlayStudio/Sources/3D/RouteSceneBuilder.swift`:

1. **Smooth curves** - Use Catmull-Rom or Bezier interpolation between points instead of straight segments

2. **Better tubes** - Use `SCNShape` with extrusion or custom geometry for smoother tubes

3. **Variable thickness** - Optionally vary tube radius based on pace (thicker = slower)

4. **Color gradient** - Add option to color route by:
   - Pace (blue=fast, red=slow)
   - Heart rate (green=low, red=high)
   - Elevation (low=green, high=brown)

5. **Start/Finish markers** - Improve markers with 3D text labels

6. **Performance** - Ensure smooth rendering with 1000+ point routes

## Files to Modify

- `RunPlayStudio/Sources/3D/RouteSceneBuilder.swift`
- `RunPlayStudio/Sources/3D/RouteColorStrategy.swift` (create)

## Acceptance Criteria

- [ ] Route appears smooth even with sparse GPS data
- [ ] Color gradient option works for pace/HR/elevation
- [ ] Performance is acceptable for 1000+ points
- [ ] Start/finish markers are clearly visible
