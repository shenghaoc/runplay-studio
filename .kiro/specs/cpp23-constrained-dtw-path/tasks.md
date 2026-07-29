# Tasks: C++23 Constrained DTW Path

Checked boxes record intended work. Tests and CI are the completion evidence.

## Implementation

- [x] Add `RouteAlignmentDtw.hpp` with the cost sample, solver policy, path
      cell, status, and summary aggregates plus their standard-layout asserts
- [x] Add `RouteAlignmentDtw.cpp` implementing band radius, packed row layout,
      budget validation, point cost, open-beginning seeding, constrained
      transitions with diagonal → primary-only → comparison-only tie priority,
      warp-run capping, open-suffix endpoint selection, and reconstruction
- [x] Include the alignment header from the umbrella public header
- [x] Add `RunPlayRouteAlignmentDtwBridge` performing exactly one native call
      per alignment attempt, owning both inputs and the `n + m + 1` output
      buffer, and validating the returned path
- [x] Cut `ConstrainedDynamicTimeWarpingAligner` over to the bridge while
      keeping Swift sample construction, direction detection, blocks,
      diagnostics, quality, and public models
- [x] Add native C++ tests for buffer contracts, policy and input-contract
      rejection, band-budget rejection, no-path, tie-breaking, warp capping,
      endpoint selection, and no-write-on-failure
- [x] Add the Swift path oracle and parity tests over deterministic fixtures
- [x] Add the end-to-end pre-migration aligner oracle and snapshot parity tests
- [x] Update the public AST validator and `scripts/validate-cpp-boundaries.sh`
      for the new entry point and bridge isolation
- [x] Add the opt-in release benchmark for the alignment path
- [x] Write this spec and update durable docs (`AGENTS.md`, `README.md`,
      `docs/architecture.md`, `docs/phase-plan.md`)

## Verification evidence required

Checked boxes record intended work. Tests and CI are the completion evidence.

- [x] `./scripts/validate-cpp-boundaries.sh`
- [x] public AST self-test and live header scan
- [x] `swift build --target RunPlayEngineCpp` with strict warnings
- [x] native tests (normal + `--sanitize`)
- [x] native harness through `swift test` (`NativeEngineTests`)
- [x] `swift test --filter RunPlayRouteAlignmentDtwBridgeTests`
- [x] `swift test --filter DynamicTimeWarpingRouteAlignerTests`
- [x] `swift test --filter RunPlayCoreTests`
- [x] package-consumer smoke build
- [x] full `swift test` on macOS and `xcodebuild test`
- [ ] Route-Aware comparison GUI check from `docs/manual-testing.md`
      (manual; not yet performed)

## Notes

- The DTW boundary is the first boundary that borrows **two** const input
  buffers in one call. It is not capacity-negotiated: a valid path never
  exceeds `n + m + 1` cells, so Swift allocates that proven bound and
  `insufficient_output_capacity` is treated as an engine contract violation
  rather than a retry signal.
- Cancellation is cooperative and lives entirely in Swift — around conversion,
  around the native call, and during output translation. The engine takes no
  cancellation callback, so the `maximumBandCells` budget (4,000,000) is what
  bounds the uninterruptible native window.
- Only the path solve migrated. Alignment sample construction, direction
  detection, aligned metrics, and the rest of comparison remain Swift.
