# Tasks: Final Portable Core Cleanup

Checked boxes record intended work. Tests and CI are the completion evidence.

## Workstream A — Boundary inventory

- [x] Create `docs/cpp-engine-boundary-inventory.md` covering every public
      callable and struct with the required metadata (name, header, signature,
      pointer roles, capacity contract, error statuses, no-write guarantees,
      native-call cardinality, production caller, and status).
- [x] Confirm "remaining count: 0" transitional boundaries.

## Workstream B — Step-distance removal

- [x] Delete `RouteGeometry.hpp`, `RouteGeometry.cpp`, `RouteGeometryTests.cpp`,
      `RunPlayRouteStepDistanceBridge.swift`,
      `RunPlayRouteStepDistanceBridgeTests.swift`, `RouteStepDistanceBenchmark.swift`,
      `scripts/run-step-distance-benchmark.sh`.
- [x] Update umbrella header, `TestMain.cpp`, `validate-cpp-boundaries.sh`,
      `validate-cpp-public-ast.py`, `Package.swift` comment.
- [x] Verify no `compute_route_step_distances` / `RunPlayRouteStepDistanceBridge`
      references remain.

## Workstream C — Pointer/lifetime audit

- [x] Audit all remaining public callables (const inputs, caller-owned outputs,
      exact write counts, capacity negotiation, no-write on error).
- [x] Document findings in the boundary inventory.

## Workstream D — Header dependency audit

- [x] Verify every public header depends only on stdlib + public engine headers.
- [x] Verify umbrella header remains valid after removal.

## Workstream E — Swift facade audit

- [x] Confirm only `RunPlayCore/Sources/Interop/` imports `RunPlayEngineCpp`.
- [x] Confirm no C++ type escapes into public `RunPlayCore` APIs.
- [x] Confirm nonescaping pointer scopes, cancellation, no hidden fallback.

## Workstream F — Call-cardinality enforcement

- [x] Add tests proving one native call per production operation.
- [x] Add zero-call coverage for corrected-elevation finalization and solid mode.

## Workstream G — Oracle classification

- [x] Classify every oracle in the test target as active or removed.
- [x] Remove any migration-decision-only oracle with no active consumer.
      (Nine oracles are retained, each with named active consumers; none is
      migration-decision-only. Seven are file-level:
      `SwiftRouteQualityGeometryOracle` — RunPlayRouteQualityBridgeTests,
      RouteQualityPipelineBenchmark; `SwiftElevationProfileOracle` —
      ElevationProfileParityTests, RunPlayElevationProfileBridgeTests,
      ElevationProfileBenchmark; `SwiftPersonalHeatmapBuilderOracle` —
      PersonalHeatmapBuilderOracleParityTests,
      PersonalHeatmapAggregationOptimizationTests,
      PersonalHeatmapCoverageBenchmark, PersonalHeatmapPipelineProfile;
      `SwiftRouteMetricScaleBucketOracle` — RouteMetricScaleBucketParityTests,
      RouteMetricScaleBucketCompatibilityTests,
      RunPlayRouteMetricScaleBucketBridgeTests,
      RouteMetricScaleBucketBenchmark; `SwiftSegmentDetectorOracle` —
      SegmentDetectorParityTests, RunPlaySegmentDetectorBridgeTests,
      SegmentDetectorBenchmark; `SwiftConstrainedDtwPathOracle` —
      RunPlayRouteAlignmentDtwBridgeTests, RouteAlignmentDtwBenchmark,
      DynamicTimeWarpingRouteAlignerTests, PreMigrationRouteAlignerOracle;
      `PreMigrationRouteAlignerOracle` — DynamicTimeWarpingRouteAlignerTests.
      Two are private nested types: `SwiftRouteInspectionOracle` inside
      RunPlayRouteBridgeTests, pinning the inspection field digest, and
      `SwiftWorkoutCoverageOracle` inside
      RunPlayPersonalHeatmapCoverageBridgeTests, pinning per-workout coverage.
      The boundary inventory's verification-coverage table maps each oracle to
      its boundary.)

## Workstream H — Verification document + benchmark inventory

- [x] Create `docs/cpp-engine-verification.md` with the full benchmark/profile
      inventory, sanitizer matrix, and discovery-coverage proof.
- [x] Remove the step-distance benchmark script; reframe
      `RemainingCoreHotspotProfile` as a production diagnostic.
      (Step-distance script removed in Workstream B; the hotspot profile is a
      release production diagnostic gated on `RUNPLAY_CORE_HOTSPOT_PROFILE=1`
      with family selection — no migration-decision-only ranking material.)

## Workstream I — Discovery and sanitizer coverage

- [x] Add a discovery-coverage guard proving added-but-omitted native files fail.
- [x] Document normal vs ASan/UBSan participation.

## Workstream J — Package-consumer smoke

- [x] Strengthen `Tests/PackageConsumerSmoke` with representative
      `RunPlayCore` usage, run as a compile-and-run external-consumer smoke.
- [x] Verify `swift build --package-path Tests/PackageConsumerSmoke`.

## Workstream K — iOS readiness

- [x] Create `docs/portable-core-ios-readiness.md`.

## Workstream L — Durable docs

- [x] Update `AGENTS.md`, `README.md`, `docs/architecture.md`,
      `docs/phase-plan.md`; mark migration complete; remaining count 0.
      (AGENTS.md and phase-plan already current; fixed stale "elevation remains
      Swift until later migration PRs" prose in `docs/architecture.md`.)

## Verification

- [x] `./scripts/validate-cpp-boundaries.sh`
- [x] `python3 scripts/validate-cpp-public-ast.py --self-test`
- [x] strict engine build with warning flags
- [x] native tests (normal + `--sanitize`)
- [x] `swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors`
- [x] `swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors`
- [x] `swift build --package-path Tests/PackageConsumerSmoke`
- [x] full macOS `swift test -Xswiftc -warnings-as-errors`
- [x] `xcodebuild test -scheme RunPlayStudio-Package -destination 'platform=macOS'`
- [x] grep audits and `git diff --check`

## Commit and PR

- [x] Commit "refactor: complete portable core migration cleanup"
- [x] Push to `codex/final-portable-core-cleanup`
- [x] Open draft PR "Complete portable C++23 engine migration cleanup" with the
      objective, scope, non-goals, validation actually run, remaining manual
      checks, and dependent/conflicting PRs in the PR body (PR #98).
