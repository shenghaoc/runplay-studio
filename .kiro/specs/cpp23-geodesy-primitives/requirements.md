# Requirements: C++23 Geodesy Primitives

## Introduction

Add an allocation-free C++23 geodesy kernel equivalent to the production Swift
`GeoDistance` implementation: coordinate validation, Haversine distance, and
latitude/longitude-to-local-metre projection.

This phase is a literal migration of existing formulas plus parity evidence. It
is not an accuracy redesign and not a production cutover.

Explicitly, for this PR:

- C++ geodesy is implemented and parity-tested against Swift.
- Swift `GeoDistance` remains the production implementation.
- No production route loop crosses into C++ per point.
- The next route-pipeline PR will consume these primitives *inside* C++, after
  one bulk route call has already crossed the boundary.
- Checked task boxes do not replace test and CI evidence.

## Requirements

### R1. Coordinate validation

- C++ exposes `is_valid_coordinate(double, double) noexcept`.
- Both values must be finite; latitude within `-90...90` and longitude within
  `-180...180`, inclusive on both ends.
- Positive and negative zero are accepted.
- NaN and both infinities are rejected in either field.
- Results match Swift `GeoDistance.isValidCoordinate(lat:lon:)` exactly for a
  deterministic matrix of boundary, just-inside, just-outside, signed-zero,
  non-finite, and per-hemisphere values.

### R2. Haversine distance

- C++ exposes `haversine_distance_meters(double, double, double, double) noexcept`.
- Returns positive `0.0` when either coordinate pair fails validation.
- Uses `earth_radius_meters = 6'371'000.0`, matching the Swift constant exactly.
  No WGS-84 equatorial or polar radius, no ellipsoid, no third-party constant.
- Applies the existing Haversine formula in the existing operation order,
  including `degrees * pi / 180` evaluated left to right.
- No longitude normalisation, no clamping of the haversine term, no ellipsoidal
  correction, no float arithmetic, no `std::pow`.

### R3. Local metre projection

- C++ exposes
  `project_lat_lon_to_local_meters(double, double, double, double) noexcept`
  returning a named `LocalMeters` value.
- Uses the existing equirectangular coefficients and operation order.
- Does not validate, clamp, or wrap inputs; non-finite values propagate.

### R4. Preserved numerical semantics

- Results are bit-identical to Swift on a given platform. Floating-point
  contraction must not fuse a multiply-add where Swift performs two rounded
  operations.
- Existing limitations are preserved rather than repaired. In particular, some
  exactly antipodal pairs round the haversine term above 1, so `sqrt(1 - a)`
  yields NaN. Both implementations must produce NaN for the same inputs.

### R5. Allocation-free value boundary

- `LocalMeters` is standard-layout, trivially copyable, and nothrow
  copy-constructible, with no pointers, references, virtual methods, bases, or
  dynamic allocation.
- The public API exposes no `std::pair`, `std::tuple`, `std::variant`,
  `std::vector`, `std::string`, raw pointers, templates, exceptions, or
  ownership-bearing handles.
- Every public callable is `[[nodiscard]]` and `noexcept`.
- `EngineInfo.abi_version` is unchanged; these are additive source-level APIs.

### R6. Parity-only Swift adapter

- `RunPlayGeodesyBridge` is internal to `RunPlayCore/Sources/Interop`.
- It converts `LocalMeters` immediately into a pure Swift `RunPlayLocalMeters`
  and exposes no C++ type in its signatures.
- It contains no feature flag, engine selector, or runtime logging.
- It is unused by production code, enforced mechanically by
  `scripts/validate-cpp-boundaries.sh` rather than by comment.

### R7. Verification

- Independent native C++ tests cover validation, distance, and projection,
  using published reference ranges rather than restating the implementation.
- Swift parity tests use `GeoDistance` as the oracle over deterministic
  fixtures, with tolerance `max(1e-6, abs(reference) * 1e-12)` for finite
  results and classification comparison for NaN and signed infinities.
- Fixtures are deterministic; no nondeterministic random generator is used.
- ASan and UBSan execute the geodesy tests.
- The public AST validator rejects throwing geodesy functions, geodesy pointer
  parameters, `std::pair`/`std::tuple`/`std::variant`/`std::vector` geodesy
  returns, and public geodesy templates.

## Non-Goals

Production cutover of `GeoDistance`, `RouteQualityProcessor`, route or
comparison projection, heatmap projection, route alignment, DTW,
interpolation, elevation, or importers. No GeographicLib or other dependency.
No Earth-radius or formula change. No persistence, analysis-version, or UI
change. No performance claim, benchmark, runtime flag, telemetry, CMake,
Objective-C++, C ABI, or toolchain change.
