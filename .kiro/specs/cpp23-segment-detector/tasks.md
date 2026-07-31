# SegmentDetector C++23 Migration — Tasks

## Implemented

- [x] C++ header: SegmentDetection.hpp
- [x] C++ implementation: SegmentDetection.cpp
- [x] WorkoutTimelineSegmentDetectionSnapshot
- [x] ElevationSegmentDetectionSnapshot
- [x] RunPlaySegmentDetectorBridge.swift
- [x] SegmentDetector integration (replaced 5 search loops)
- [x] Native C++ tests (SegmentDetectionTests.cpp)
- [x] All SegmentDetectionTests pass (25/25)
- [x] All RunPlayCoreTests pass
- [x] All RunPlayPlatformTests pass
- [x] RunPlayEngineCppTests pass
- [x] PackageConsumerSmoke builds

## Remaining

- [ ] SwiftSegmentDetectorOracle (test-only independent Swift oracle)
- [ ] RunPlaySegmentDetectorBridgeTests (generated fixture parity)
- [ ] SegmentDetectorParityTests (end-to-end highlight parity)
- [ ] SegmentDetectorBenchmark + benchmark script
- [ ] Update validate-cpp-public-ast.py
- [ ] Update validate-cpp-boundaries.sh
- [ ] Update AGENTS.md, README.md, docs/architecture.md, docs/phase-plan.md
- [ ] Create draft PR
