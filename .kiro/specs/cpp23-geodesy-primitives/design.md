# Design: C++23 Geodesy Primitives

## Intended architecture after this PR

```text
RunPlayStudio
    ↓
RunPlayPlatform
    ↓
RunPlayCore
    ├── production Swift GeoDistance remains authoritative temporarily
    └── internal parity-only RunPlayGeodesyBridge
            ↓
      RunPlayEngineCpp
      ├── engine identity
      ├── route input and inspection boundary
      └── C++23 geodesy primitives
```

## Why no production cutover in this phase

Every production `GeoDistance` caller runs inside a per-point loop. Confirmed
call sites include `RouteQualityProcessor` (distance accumulation and per-point
validation), `MovementProfile` (per-sample displacement), `RouteProjectionService`
and `ComparisonRouteProjectionService` (per-point validation and projection),
`RouteAlignmentSampleBuilder`, `PersonalHeatmapBuilder`, `WorkoutComparisonService`,
`WorkoutAnalyzer`, and the GPX/TCX/FIT/JSON importers.

Making `GeoDistance.distanceMeters` delegate to C++ would therefore produce one
Swift-to-C++ call per point pair. `AGENTS.md` and `docs/architecture.md` forbid
per-element cross-language calls, so that would establish exactly the wrong
long-term boundary.

The primitives added here are instead the tested engine building blocks that a
later C++ route algorithm calls *internally*, after a single bulk route call has
already crossed the boundary.

## Public C++ API

`RunPlayEngineCpp/include/RunPlayEngineCpp/Geodesy.hpp`, included from the
`RunPlayEngine.hpp` umbrella header:

```cpp
inline constexpr double earth_radius_meters = 6'371'000.0;

struct LocalMeters final {
    double x_meters;
    double z_meters;
};

[[nodiscard]] bool is_valid_coordinate(double, double) noexcept;
[[nodiscard]] double haversine_distance_meters(double, double, double, double) noexcept;
[[nodiscard]] LocalMeters project_lat_lon_to_local_meters(double, double, double, double) noexcept;
```

`LocalMeters` is a named aggregate rather than `std::pair` or `std::tuple` so
Swift reads documented fields instead of positional elements, and so the value
stays trivially copyable across the boundary.

Only `<type_traits>` is included publicly; the implementation adds `<cmath>` and
`<numbers>`. The private `degrees_to_radians` helper stays in an anonymous
namespace in `Geodesy.cpp`.

## Numerical fidelity

Two details preserve bit-level parity with Swift.

**Operation order.** Swift evaluates `degrees * .pi / 180` left to right, so it
multiplies before dividing. `degrees_to_radians` reproduces that rather than
folding a `pi / 180` constant, which would round differently.

**No multiply-add contraction.** Clang defaults to `-ffp-contract=on`, which may
fuse a multiply and an add appearing in the same statement; Swift never
contracts. The C++ implementation therefore splits each accumulation so no
statement contains both a multiply and an add:

```cpp
const double latitudinal_term = half_delta_latitude_sine * half_delta_latitude_sine;
const double longitudinal_term = latitude_cosine_product
    * half_delta_longitude_sine * half_delta_longitude_sine;
const double a = latitudinal_term + longitudinal_term;
```

The same split applies to the projection harmonics. The resulting operation tree
is identical to Swift, so both implementations agree bit for bit on one
platform. Tolerance in the parity tests exists only for macOS/Linux libm
differences in `sin`, `cos`, and `atan2`.

## Preserved limitations

The projection performs no validation, clamping, or antimeridian wrapping, and
propagates non-finite inputs.

For some exactly antipodal pairs — `(12, 34)` to `(-12, -146)`, for example —
the rounded haversine term exceeds 1, so `sqrt(1 - a)` is NaN and the distance
is NaN. Swift already behaves this way. C++ reproduces it exactly, and both
native and parity tests assert the NaN rather than hiding it. Repairing this
would change existing analysis results and belongs to a separate, explicitly
scoped decision.

## Swift adapter

`RunPlayGeodesyBridge` is internal, converts `LocalMeters` into a pure Swift
`RunPlayLocalMeters` inside a nested call so the imported C++ temporary is
destroyed before returning, and is called only by tests.

## Boundary enforcement

`scripts/validate-cpp-public-ast.py` gains `std::pair` / `std::tuple` /
`std::variant` rejection alongside the existing `std::vector` rule, plus
self-test fixtures naming the geodesy declarations and adversarial cases for a
throwing geodesy function, a geodesy pointer out-parameter, positional-type
returns, and a public geodesy function template.

`scripts/validate-cpp-boundaries.sh` gains a scan proving no Swift file outside
`RunPlayGeodesyBridge.swift` and the test targets references
`RunPlayGeodesyBridge` or `RunPlayLocalMeters`, plus an explicit check that
`GeoDistance.swift` remains an independent Swift implementation.

The existing route pointer exception, vector rejection, template rejection,
namespace-envelope checks, Swift import confinement, and package-graph
validation are unchanged.

## Test discovery

`scripts/run-cpp-engine-tests.sh` already discovers every `.cpp` under
`RunPlayEngineCpp/Sources` and `RunPlayEngineCpp/Tests`, so `Geodesy.cpp` and
`GeodesyTests.cpp` are compiled by both the normal and sanitizer builds without
script changes. `Package.swift` needs no change either: the engine target
already globs its `Sources` directory.
