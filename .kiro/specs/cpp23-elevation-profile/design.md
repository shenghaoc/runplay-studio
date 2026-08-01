# ElevationProfile C++23 Migration — Design

## Boundary

```text
RoutePoint altitude/distance/continuity
→ one ElevationProfileInputSample buffer
→ one build_elevation_profile call
→ one output entry per input point
→ Swift ElevationProfile
```

Swift owns every buffer. C++ retains nothing and performs no callback.

## Public C++ API

- Header: `RunPlayEngineCpp/include/RunPlayEngineCpp/ElevationProfile.hpp`
- Function: `build_elevation_profile(const ElevationProfileInputSample*, size_t, ElevationProfilePolicy, ElevationProfileOutputSample*, size_t) noexcept`
- Empty input allows null buffers and returns success with zero capacity.
- Nonempty input requires non-null buffers and capacity ≥ sample count.
- Failures return before the first output write.
- After validation, output is the route-sized workspace (no `std::vector`).

## Continuity contract

- Continuity groups begin at zero, never decrease, increase by at most one.
- `has_altitude` is exactly 0 or 1.
- Present non-finite altitude is rejected as data, not treated as missing.
- Malformed distances are processed with the same arithmetic as the pre-migration Swift path (no new public strictness).

## Semantics preserved literally

- Endpoint spikes use an immutable pre-mutation snapshot of sanitized altitudes.
- Isolated interior spikes mutate left-to-right on working altitudes.
- Short excursions advance the scan cursor past rejected plateaus.
- Rejected-sample fills do not chain (snapshot then apply).
- Reliable-run IDs keep normal run-ID gaps when short unreliable runs intervene.
- Smoothing is centered distance-domain moving average within a reliable run only; endpoints of each run are restored.
- Gain/loss uses threshold-confirmed trend reversal with end-of-run provisional totals.

## Swift ownership

- Bridge: `RunPlayElevationProfileBridge` (Interop only).
- Production `ElevationProfile.build` calls the pure-Swift bridge once.
- SegmentDetector continues to consume `segmentDetectionSnapshot()`.

## Parity strategy

- Independent oracle: `SwiftElevationProfileOracle` in tests only.
- Native unit tests for each stage.
- 1,000 generated bridge fixtures.
- Production parity and existing `ElevationProfileTests`.
