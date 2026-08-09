# Tasks: Comparison Replay Video Export

## 1. Specifications

- [x] requirements.md
- [x] design.md
- [x] tasks.md

## 2. RunPlayCore

- [x] ComparisonVideoExportConfiguration + errors / progress phases (reuse shared video policy)
- [x] ComparisonVideoFramePlan + domain arithmetic
- [x] ComparisonVideoFrameSample + route position models
- [x] ComparisonVideoExportEligibility
- [x] ComparisonVideoSampler (Distance + Route-Aware)
- [x] ComparisonVideoAlignmentSeed + Resolver
- [x] Comparison video filename builder
- [x] Core unit tests (plan, sampler, eligibility, resolver, filename)

## 3. Shared encoder refactor

- [x] OfflineVideoFrameProviding protocol
- [x] OfflineH264VideoAssetEncoder (writer, validate, transaction)
- [x] Refactor WorkoutVideoAssetEncoder to delegate
- [x] Single-workout parity tests

## 4. RunPlayPlatform comparison video

- [x] ComparisonVideoRoutePixelMap (gap-safe distance interpolation)
- [x] ComparisonVideoMapPreparation + preparer (one MapKit snapshot, both routes)
- [x] ComparisonVideoFrameModel + ComparisonVideoFrameRenderer
- [x] ComparisonVideoExporter (orchestrator + poster)
- [x] Platform unit tests (pixel map, map prep, renderer, exporter)

## 5. RunPlayStudio

- [x] ComparisonVideoExportViewModel
- [x] ComparisonVideoExportSheet
- [x] CompareView shared export action (wide + compact)
- [x] Accessibility announcements
- [x] Modal command blocking
- [x] Studio tests (view model, UI where practical)

## 6. Documentation

- [x] README / PRODUCT / DESIGN
- [x] docs/architecture, privacy, manual-testing, phase-plan
- [ ] Remaining data-model / accessibility-audit polish if needed

## 7. Validation

- [x] Focused comparison + single-workout video tests
- [x] Full warning-clean test suite
- [x] C++ boundary + engine tests unchanged
- [x] Package consumer smoke
- [x] Release packaging regression
- [ ] Manual Distance + Route-Aware MP4 inspection — requires packaged-app QuickTime verification (not CI-coverable)
- [x] Draft PR with full description
