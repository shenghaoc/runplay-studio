# SegmentDetector C++23 Migration — Tasks

## Implemented

- [x] C++ header: SegmentDetection.hpp
- [x] C++ implementation: SegmentDetection.cpp
- [x] WorkoutTimelineSegmentDetectionSnapshot
- [x] ElevationSegmentDetectionSnapshot
- [x] RunPlaySegmentDetectorBridge.swift
- [x] SegmentDetector integration (replaced 5 search loops)
- [x] Native C++ tests (SegmentDetectionTests.cpp)
- [x] SwiftSegmentDetectorOracle (test-only independent Swift oracle)
- [x] RunPlaySegmentDetectorBridgeTests (1,000 production-shaped generated fixtures plus named edge parity)
- [x] SegmentDetectorParityTests (1,000 generated and named end-to-end durable highlight parity fixtures)
- [x] SegmentDetectorBenchmark + release benchmark script, including the one-million-point product-limit probe
- [x] Rerun the post-cutover remaining-core analysis profile at the product limit and update the next-boundary roadmap
- [x] Update validate-cpp-public-ast.py
- [x] Update validate-cpp-boundaries.sh
- [x] Update AGENTS.md, docs/architecture.md, and docs/phase-plan.md
- [x] Review README.md; existing user-facing Segment detection description remains accurate
- [x] Open the PR early and keep its live metadata synchronized
- [x] All SegmentDetectionTests pass (25/25)
- [x] All RunPlayCoreTests pass
- [x] All RunPlayPlatformTests pass
- [x] RunPlayEngineCppTests pass
- [x] PackageConsumerSmoke builds
