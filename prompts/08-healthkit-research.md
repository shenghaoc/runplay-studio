# Prompt: Research HealthKit Integration

## Context

RunPlay Studio currently imports from files. Users with Apple Watch want direct HealthKit import on macOS.

## Task

Research and implement HealthKit integration:

1. **Research macOS HealthKit**:
   - What workout types are available?
   - What data can be accessed?
   - What permissions are needed?
   - Limitations compared to iOS?

2. **Design import flow**:
   - Permission request UI
   - Workout selection UI
   - Data mapping from HKWorkout to RunWorkout

3. **Implement basic import**:
   - Query workouts from HealthKit
   - Extract route data from workout routes
   - Map to internal model

4. **Handle limitations**:
   - Some data may not be available
   - Graceful degradation
   - Clear user messaging

## Files to Create/Modify

- `RunPlayStudio/Sources/Importers/HealthKitImporter.swift`
- `RunPlayStudio/Sources/Views/HealthKitImportView.swift` (create)
- `docs/architecture.md`

## Acceptance Criteria

- [ ] Research documented in code comments
- [ ] Permission flow works
- [ ] Can import basic workout data
- [ ] Handles missing data gracefully
- [ ] User understands limitations
