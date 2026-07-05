# Prompt: Improve 3D Camera Controls

## Context

RunPlay Studio's 3D view needs better camera controls for exploring routes from different angles.

## Task

Improve camera controls in `RunPlayStudio/Sources/3D/SceneCameraController.swift` and related views:

1. **Smooth orbit** - Add momentum/inertia to orbit gestures

2. **Follow mode** - Camera follows the replay marker with configurable offset

3. **Top-down view** - Quick button to switch to bird's eye view

4. **Side profile** - Quick button to view route from the side (elevation visible)

5. **Auto-rotate** - Optional slow auto-rotation for presentation mode

6. **Keyboard shortcuts** - Add keyboard controls:
   - Arrow keys for orbit
   - +/- for zoom
   - R for reset
   - 1-4 for preset views

7. **Gesture handling** - Proper trackpad gesture handling for:
   - Two-finger scroll for zoom
   - Click-drag for orbit
   - Right-click-drag for pan

## Files to Modify

- `RunPlayStudio/Sources/3D/SceneCameraController.swift`
- `RunPlayStudio/Sources/Views/Route3DReplayView.swift`

## Acceptance Criteria

- [ ] Orbit feels smooth and responsive
- [ ] Follow mode works during replay
- [ ] Preset views (top-down, side) work correctly
- [ ] Keyboard shortcuts function
- [ ] Trackpad gestures feel natural
