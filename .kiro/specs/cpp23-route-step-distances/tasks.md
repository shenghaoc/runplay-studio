# Tasks: C++23 Route Step Distances

Checked boxes record intended work. Tests and CI are the completion evidence.

## Implementation

- [x] Add `RouteGeometry.hpp` / `RouteGeometry.cpp` with status, summary, and
      bulk `compute_route_step_distances`
- [x] Include the geometry header from the umbrella public header
- [x] Extract shared `RunPlayRouteInputBuffer`
- [x] Update `RunPlayRouteBridge` to use the shared builder
- [x] Add `RunPlayRouteStepDistanceBridge`
- [x] Cut over coordinate-derived steps in `normalizeDistances`
- [x] Extend native and Swift parity / integration tests
- [x] Update public AST and boundary validators
- [x] Update durable docs (`AGENTS.md`, README, architecture, phase plan)

## Verification evidence required

Checked boxes record intended work. Tests and CI are the completion evidence.

- [x] `./scripts/validate-cpp-boundaries.sh`
- [x] public AST self-test and live header scan
- [x] native tests (normal + sanitize)
- [x] `swift test --filter RunPlayEngineCppTests`
- [x] `swift test --filter RunPlayRouteStepDistanceBridgeTests`
- [x] `swift test --filter RouteQualityProcessorTests`
- [x] `swift test --filter RunPlayCoreTests`
- [x] package-consumer smoke
- [x] full `swift test` on macOS
