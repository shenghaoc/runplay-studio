---
inclusion: fileMatch
fileMatchPattern:
  - "**/*.swift"
---

# RunPlay Studio — Swift 6 concurrency conventions

Swift 6 strict concurrency is enforced across the entire package. Follow these
patterns consistently.

## Actor boundaries

- UI state in `AppState` and `ReplayController` is isolated to `@MainActor` and
  currently uses Combine's `ObservableObject` / `@Published` model.
- Workout-library persistence and mutations are serialized through
  `WorkoutLibraryStoreActor` (an `actor` in `RunPlayCore`).
- `WorkoutImportService` is an `actor` in `RunPlayCore`; parsing never runs on
  `@MainActor`.
- Values passed across actor boundaries must conform to `Sendable`; preserve
  the explicit conformances on the relevant `RunPlayCore` models.

## Rules

- Do not add `@unchecked Sendable` merely to suppress a concurrency error.
  Prefer checked conformance; when unchecked conformance is unavoidable for a
  lock-protected or otherwise externally synchronized type, document and test
  the invariant.
- Never mutate `@MainActor` state from a background task directly. Use `await
  MainActor.run { }` or `@MainActor` method dispatch.
- Do not introduce `DispatchQueue` or `OperationQueue` — use Swift structured
  concurrency (`async`/`await`, `Task`, `actor`) exclusively.
- `RunPlayCore` must not import Combine. `RunPlayPlatform` may use Combine for
  non-UI observable controllers only.

## Observable pattern

View models currently use Combine observation:

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var workouts: [RunWorkout] = []
    @Published var selectedWorkout: RunWorkout?
    // ...
}
```

`RunPlayStudioApp` owns `AppState` and `AppSessionController` with
`@StateObject`; `ContentView` receives them by injection. Dependent views
observe `AppState` or `ReplayController` with `@ObservedObject`. Match the live
source when changing observation rather than migrating the architecture
incidentally.

`FileAppSessionStore` is an actor. It performs bounded atomic session JSON I/O
off the main actor. `AppSessionController` applies a validated snapshot only
after library startup, suppresses writes during restoration, debounces
structural changes, throttles replay updates, and flushes on pause/lifecycle
transitions. Session snapshots must remain logical and must not carry route
arrays, map/cache values, timer state, or transient presentations.

## Cross-layer data flow

```
WorkoutLibraryStoreActor (actor, RunPlayCore)
    ↓ await
AppState (@MainActor, RunPlayStudio)
    ↓ @Published property
SwiftUI View (implicit MainActor)
```

Never skip a layer or call across this chain without `await`.
