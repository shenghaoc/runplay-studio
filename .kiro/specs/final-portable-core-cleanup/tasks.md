# Tasks: Final Portable Core Cleanup

Checked boxes record intended work. Tests and CI are the completion evidence.

## Workstream A — Boundary inventory

- [ ] Create `docs/cpp-engine-boundary-inventory.md` covering every public
      callable and struct with the required metadata (name, header, signature,
      pointer roles, capacity contract, error statuses, no-write guarantees,
      native-call cardinality, production caller, and status).
- [ ] Confirm "remaining count: 0" transitional boundaries.

## Workstream B — Step-distance removal

- [ ] Delete `RouteGeometry.hpp`, `RouteGeometry.cpp`, `RouteGeometryTests.cpp`,
      `RunPlayRouteStepDistanceBridge.swift`,
      `RunPlayRouteStepDistanceBridgeTests.swift`, `RouteStepDistanceBenchmark.swift`,
      `scripts/run-step-distance-benchmark.sh`.
- [ ] Update umbrella header, `TestMain.cpp`, `validate-cpp-boundaries.sh`,
      `validate-cpp-public-ast.py`, `Package.swift` comment.
- [ ] Verify no `compute_route_step_distances` / `RunPlayRouteStepDistanceBridge`
      references remain.

## Workstream C — Pointer/lifetime audit

- [ ] Audit all remaining public callables (const inputs, caller-owned outputs,
      exact write counts, capacity negotiation, no-write on error).
- [ ] Document findings in the boundary inventory.

## Workstream D — Header dependency audit

- [ ] Verify every public header depends only on stdlib + public engine headers.
- [ ] Verify umbrella header remains valid after removal.

## Workstream E — Swift facade audit

- [ ] Confirm only `RunPlayCore/Sources/Interop/` imports `RunPlayEngineCpp`.
- [ ] Confirm no C++ type escapes into public `RunPlayCore` APIs.
- [ ] Confirm nonescaping pointer scopes, cancellation, no hidden fallback.

## Workstream F — Call-cardinality enforcement

- [ ] Add tests proving one native call per production operation.
- [ ] Add zero-call coverage for corrected-elevation finalization and solid mode.

## Workstream G — Oracle classification

- [ ] Classify every oracle in the test target as active or removed.
- [ ] Remove any migration-decision-only oracle with no active consumer.

## Workstream H — Verification document + benchmark inventory

- [ ] Create `docs/cpp-engine-verification.md` with the full benchmark/profile
      inventory, sanitizer matrix, and discovery-coverage proof.
- [ ] Remove the step-distance benchmark script; reframe
      `RemainingCoreHotspotProfile` as a production diagnostic.

## Workstream I — Discovery and sanitizer coverage

- [ ] Add a discovery-coverage guard proving added-but-omitted native files fail.
- [ ] Document normal vs ASan/UBSan participation.

## Workstream J — Package-consumer smoke

- [ ] Strengthen `Tests/PackageConsumerSmoke` with representative compile-only
      `RunPlayCore` usage.
- [ ] Verify `swift build --package-path Tests/PackageConsumerSmoke`.

## Workstream K — iOS readiness

- [ ] Create `docs/portable-core-ios-readiness.md`.

## Workstream L — Durable docs

- [ ] Update `AGENTS.md`, `README.md`, `docs/architecture.md`,
      `docs/phase-plan.md`; mark migration complete; remaining count 0.

## Verification

- [ ] `./scripts/validate-cpp-boundaries.sh`
- [ ] `python3 scripts/validate-cpp-public-ast.py --self-test`
- [ ] strict engine build with warning flags
- [ ] native tests (normal + `--sanitize`)
- [ ] `swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors`
- [ ] `swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors`
- [ ] `swift build --package-path Tests/PackageConsumerSmoke`
- [ ] full macOS `swift test -Xswiftc -warnings-as-errors`
- [ ] `xcodebuild test -scheme RunPlayStudio-Package -destination 'platform=macOS'`
- [ ] grep audits and `git diff --check`

## Commit and PR

- [ ] Commit "refactor: complete portable core migration cleanup"
- [ ] Push to `codex/final-portable-core-cleanup`
- [ ] Open draft PR "Complete portable C++23 engine migration cleanup" with the
      mandated body and completion report.
