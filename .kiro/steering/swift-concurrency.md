---
inclusion: fileMatch
fileMatchPattern:
  - "**/*.swift"
---

# RunPlay Studio — Swift 6 concurrency conventions

Swift 6 strict concurrency is enforced across the entire package. Follow these
patterns consistently.

## Actor boundaries

- All UI state is owned by `@MainActor`-annotated `@Observable` classes in
  `RunPlayStudio` (`AppState`, `ReplayController`).
- All file I/O and library mutations are serialized through
  `WorkoutLibraryStoreActor` (an `actor` in `RunPlayCore`).
- `WorkoutImportService` is an `actor` in `RunPlayCore`; parsing never runs on
  `@MainActor`.
- `RunPlayCore` models are value types (`struct`, `enum`) — safe to pass across
  actor boundaries without `@Sendable` wrappers.

## Rules

- Never use `@unchecked Sendable` to suppress a concurrency error. Fix the
  underlying issue instead.
- Never mutate `@MainActor` state from a background task directly. Use `await
  MainActor.run { }` or `@MainActor` method dispatch.
- Do not introduce `DispatchQueue` or `OperationQueue` — use Swift structured
  concurrency (`async`/`await`, `Task`, `actor`) exclusively.
- `RunPlayCore` must not import Combine. `RunPlayPlatform` may use Combine for
  non-UI observable controllers only.

## Observable pattern

ViewModels use `@Observable` (Swift Observation framework, not `ObservableObject`):

```swift
@MainActor
@Observable
final class AppState {
    var workouts: [RunWorkout] = []
    var selectedWorkout: RunWorkout?
    // ...
}
```

Views access state via direct property reads — no `@StateObject`, `@ObservedObject`,
or `@EnvironmentObject` needed with `@Observable`.

## Cross-layer data flow

```
WorkoutLibraryStoreActor (actor, RunPlayCore)
    ↓ await
AppState (@MainActor, RunPlayStudio)
    ↓ @Observable property
SwiftUI View (implicit MainActor)
```

Never skip a layer or call across this chain without `await`.
