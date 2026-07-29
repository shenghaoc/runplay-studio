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

## Pre-merge review fixes

- [x] Decide adjacent-candidate retention from unmodified candidate flags
      (in-place clearing rejected the trailing member of every run, diverging
      from R3 and from `origin/main`)
- [x] Replace the vacuous adjacency test with fixtures that actually produce
      adjacent candidates, and add Swift bridge parity coverage
- [x] Make distance normalization linear per segment instead of rescanning the
      whole route once per normalized segment
- [x] Add a many-segment native test covering the linear normalization path
- [x] Guard the benchmark's Mach-only peak-RSS probe behind `canImport(Darwin)`
      so `RunPlayCoreTests` still compiles on Linux

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
