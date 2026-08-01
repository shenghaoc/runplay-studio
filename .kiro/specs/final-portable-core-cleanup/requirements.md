# Requirements: Final Portable Core Cleanup

## Introduction

Mandatory single-phase endpoint of the portable C++23 engine migration. The
goal is a fully consolidated, documented, and verified engine boundary with no
transitional migration scaffolding, no dead or unreferenced duplicates, and a
clean handoff to future platform work (including iOS).

Checked task boxes do not replace test and CI evidence. Executable truth is
source, tests, `Package.swift`, CI, and the validators.

## Scope

- Inventory every public C++ boundary callable and its structs.
- Resolve the disposition of the transitional bulk step-distance boundary
  (`compute_route_step_distances`) and its Swift bridge, tests, benchmark, and
  runner.
- Audit every raw pointer/lifetime contract on the remaining public callables.
- Audit public-header dependencies (stdlib + public headers only).
- Audit the Swift Interop facade: internal imports, no C++ type escape,
  nonescaping pointer scopes, cancellation, no hidden fallback.
- Prove one-native-call-per-operation cardinality for every production caller.
- Classify every Swift oracle/duplicate retained in the test target.
- Rationalize benchmarks/profiles and the remaining-core hotspot profile.
- Prove every native source and native test participates in normal and
  ASan/UBSan builds via automatic discovery.
- Strengthen the package-consumer smoke test with representative usage.
- Document iOS readiness.
- Update durable docs (AGENTS.md, README, architecture, phase plan) and mark
  the migration complete with remaining-phase count zero.

## Non-goals

- No new production algorithm changes, schema changes, analysis-version
  changes, or public API changes beyond the step-distance removal.
- No new third-party dependencies.
- No new native boundaries.
- No performance work outside benchmark/profile inventory.

## Requirements

### R1. Boundary inventory document

`docs/cpp-engine-boundary-inventory.md` lists every public engine callable and
public struct with the required metadata fields per boundary, and confirms
"remaining count: 0" transitional boundaries after the step-distance removal.

### R2. Step-distance disposition

The transitional `compute_route_step_distances` boundary, its Swift bridge,
native tests, Swift bridge tests, benchmark, benchmark runner, AST validator
entries, boundary validator entries, umbrella include, and all stale prose are
removed. Internal pairwise geodesy helpers retained because production
`RouteQualityPipeline` uses them.

### R3. Pointer/lifetime audit

Every remaining public callable is `noexcept`; pointer inputs are borrowed
`const`; outputs are caller-owned mutable pointers with explicit capacities;
per-sample boundaries write exactly `sample_count` entries on success and
nothing on error; capacity-negotiated and bounded-output boundaries document
their exact write/no-write contract. The audit is documented in the boundary
inventory.

### R4. Header dependency audit

Every public header depends only on C++ standard-library headers and other
public engine headers. The existing boundary validator check is retained and
verified; the umbrella header remains valid after the step-distance removal.

### R5. Swift facade audit

Only `RunPlayCore/Sources/Interop/` imports `RunPlayEngineCpp`; bridges are
internal; no C++ type appears in a public `RunPlayCore` API; pointer lifetimes
are nonescaping; cancellation is cooperative Swift work; no production path
falls back to a removed or duplicate Swift implementation.

### R6. Call-cardinality enforcement

Tests prove exactly one native call per production operation: route quality per
normalization, personal heatmap per workout per attempt, DTW per alignment
attempt, segment detection per invocation, elevation profile per build, pace
and heart-rate scale/bucket one call each, and zero calls for corrected
elevation finalization.

### R7. Oracle classification

Every Swift oracle retained in the test target is an active parity reference
with an existing consumer, or is removed. No migration-decision-only oracle
remains.

### R8. Benchmarks and profiles

`docs/cpp-engine-verification.md` inventories every benchmark/profile runner,
its gate, and its coverage. The step-distance benchmark is removed. The
remaining-core hotspot profile is retained as a general production diagnostic;
migration-decision-only ranking material is removed or reframed.

### R9. Sanitizer and discovery coverage

Every native source and native test participates in normal and ASan/UBSan
builds through automatic discovery. A guard proves coverage fails when a source
or test is added but not discovered. Documented in `docs/cpp-engine-verification.md`.

### R10. Package-consumer smoke

`Tests/PackageConsumerSmoke` exercises representative `RunPlayCore` public API
usage (models or services) beyond a bare import, still compile-only, and still
builds clean under CI.

### R11. iOS readiness document

`docs/portable-core-ios-readiness.md` documents that the engine, Core, and
validators are platform-neutral; that Apple-only paths live in
Platform/Studio; and what a future iOS product must validate.

### R12. Documentation and phase close

AGENTS.md, README.md, docs/architecture.md, and docs/phase-plan.md are updated:
no stale step-distance references; the migration is marked complete; the phase
plan records "remaining count: 0"; the completed cleanup is listed.

## Verification evidence required

- `./scripts/validate-cpp-boundaries.sh`
- `python3 scripts/validate-cpp-public-ast.py --self-test` and the live scan
- strict `swift build --target RunPlayEngineCpp` with `-Wall -Wextra -Wpedantic
  -Wconversion -Wsign-conversion -Wshadow`
- `./scripts/run-cpp-engine-tests.sh` and `--sanitize`
- `swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors`
- `swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors`
- `swift build --package-path Tests/PackageConsumerSmoke`
- `swift test -Xswiftc -warnings-as-errors` (macOS full stack)
- `xcodebuild test -scheme RunPlayStudio-Package -destination 'platform=macOS'`
- grep audits: `import RunPlayEngineCpp` outside Interop; `compute_route_step_distances`
  and `RunPlayRouteStepDistanceBridge` fully removed; `find` discovery coverage
- `git diff --check`
