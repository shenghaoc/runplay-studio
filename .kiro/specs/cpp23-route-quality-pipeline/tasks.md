# Tasks: C++23 Route Quality Geometry Pipeline

Checked boxes do not replace tests or CI.

## Implementation

- [x] Add `RouteQualityPipeline.hpp` public types and bulk function
- [x] Implement `RouteQualityPipeline.cpp` combined kernel
- [x] Extract internal pairwise step helper; reuse from route geometry
- [x] Add native `RouteQualityPipelineTests.cpp`
- [x] Add `RunPlayRouteQualityBridge` and cancellable input conversion
- [x] Cut production `RouteQualityProcessor` over to the combined bridge
- [x] Remove dead production stage 2–4 Swift helpers
- [x] Keep step-distance bridge transitional/test-focused
- [x] Update public AST and boundary validators
- [x] Add Swift oracle, parity tests, property coverage, and benchmark
- [x] Update AGENTS.md, architecture, phase-plan, and README

## Verification (executable)

Checked boxes do not replace tests or CI. Live results live in the PR and CI.

- [x] `./scripts/validate-cpp-boundaries.sh`
- [x] `python3 scripts/validate-cpp-public-ast.py --self-test`
- [x] Native C++ tests and sanitizers
- [x] `swift test --filter RunPlayEngineCppTests`
- [x] `swift test --filter RunPlayRouteQualityBridgeTests`
- [x] `swift test --filter RouteQualityProcessorTests`
- [x] `swift test --filter RunPlayCoreTests`
- [x] Package-consumer smoke build
- [x] Route-quality benchmark when `RUNPLAY_BENCHMARK=1`
