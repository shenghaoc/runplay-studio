# Implementation Tasks

- [x] Add backward-compatible `routeSegmentIndex` persistence to `RoutePoint`
  and propagate it to `RouteScenePoint`.
- [x] Preserve GPX and TCX source track boundaries during parsing and normalize
  distance independently within each segment.
- [x] Prevent cross-segment distance, speed, pace, elevation, interpolation,
  smoothing, splits, and detected highlights.
- [x] Render one map route per segment and prevent SceneKit routes and selected
  highlights from bridging a gap.
- [x] Add GPX/TCX import, persistence, analysis, split, detector, and 3D
  highlight regression coverage.
- [x] Align import, model, and architecture documentation with segment-aware
  behavior.
- [x] Run `swift build`, `swift test`, and
  `xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme RunPlayStudio -destination 'platform=macOS'`.
- [x] Run the packaged macOS app, import bundled GPX and TCX fixtures through
  the native picker, and verify the selected route renders with the native map
  controls and accessible labels.
