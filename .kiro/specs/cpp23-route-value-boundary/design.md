# Design: C++23 Route Value Boundary

## Overview

This PR extends the portable `RunPlayEngineCpp` foundation with a route-value
contract and a parity-only bulk inspection API. `RunPlayCore` remains the only
Swift facade that may import the engine. Production app code continues to use
Swift `RoutePoint` values exclusively.

## Components

### C++ route interop (`RunPlayEngineCpp`)

- `RouteInterop.hpp` defines:
  - `max_route_input_samples` (engine batch proof cap, not app workout length)
  - `RouteOptionalDouble` / `RouteOptionalSourceIndex` aliases for Swift-nameable
    `std::optional` specializations
  - `RouteInputSample` (standard-layout, copy-constructible input value)
  - `RouteInteropStatus` (`success`, `invalid_buffer`, `resource_limit`)
  - `RouteBatchInspection` compact result
  - `inspect_route_batch(const RouteInputSample*, size_t) noexcept`
- `RouteInterop.cpp` implements empty/invalid/limit handling, optional-field
  counts, segment-transition counting, and an FNV-1a-style field digest over
  exact IEEE-754 bit patterns.
- `RunPlayEngine.hpp` includes the route header so the public engine module
  surface discovers the contract with identity smoke API.

### Swift adapter (`RunPlayCore/Sources/Interop`)

- `RunPlayRouteBridge` is internal and parity-only.
- Builds a `ContiguousArray<runplay.RouteInputSample>` in source order.
- Calls `inspect_route_batch` through `withUnsafeBufferPointer`.
- Maps status and optional indexes into pure-Swift
  `RunPlayRouteBatchInspection` / `RunPlayRouteInteropStatus`.
- Nested conversion keeps temporary C++ values out of the returned pure-Swift
  result.

### Native and Swift parity tests

- Native C++ tests (`RouteInteropTests.cpp`) cover empty, invalid, resource
  limit, complete fixture digest constant, absent optionals, segment
  transitions, determinism, and a 100,000-sample heap batch under sanitizers.
- Swift tests (`RunPlayRouteBridgeTests.swift`) assert independent oracle parity
  for empty, complete, missing optionals, multi-segment, duplicate-distance
  across segment boundaries, non-finite/signed-zero bit patterns, and a
  100,000-sample route.
- `TestMain.cpp` + `TestSupport.hpp` host the multi-suite native executable;
  `scripts/run-cpp-engine-tests.sh` discovers all engine and test `.cpp` sources.

### Boundary enforcement

- `scripts/validate-cpp-boundaries.sh` checks public headers, package graph,
  Swift import confinement, and public AST rules.
- `scripts/validate-cpp-public-ast.py` allows only the documented
  `const RouteInputSample*` bulk-call pointer and rejects `std::vector` and
  other pointer leaks in the public `runplay` AST.
- `scripts/validate-swift-engine-imports.py` token/lexer-validates engine
  imports (including inactive conditional branches and adversarial fixtures).

## Data flow

```text
Swift [RoutePoint]
  → Swift-owned contiguous RouteInputSample buffer
  → inspect_route_batch(...) noexcept
  → RouteBatchInspection
  → pure-Swift RunPlayRouteBatchInspection
```

## Ownership and lifetime

1. Swift allocates and owns the contiguous input buffer.
2. C++ receives a borrowed pointer+count for one synchronous call.
3. C++ never stores the pointer and allocates nothing proportional to route
   length for inspection.
4. C++ returns one compact value.
5. Core converts that value to pure Swift before imported temporaries die.

## Identity and time policy

| Concern | Policy |
| --- | --- |
| Point UUID | Remains authoritative in Swift; not projected |
| Array position | `source_index` on each sample |
| Timestamp | Exact `timeIntervalSinceReferenceDate` bits |
| Optionals | `std::optional<double>`; no numeric sentinels |
| Segment index | Exact `Int` → `Int64` conversion |

## Non-goals

- Production algorithm migration
- Persistence / schema changes
- UI or user-visible behaviour
- Performance marketing for the inspection digest itself
- Per-point engine calls from Platform/Studio

## Verification strategy

- Boundary scripts on Linux and macOS CI
- Native C++ tests (plain and ASan+UBSan)
- SwiftPM `RunPlayEngineCppTests` harness success marker
- `RunPlayRouteBridgeTests` + full `RunPlayCoreTests`
- Full macOS package suite
- `git diff --check`
