# Implementation Tasks

- [x] Consolidate semantic colors, spacing, radii, typography, surfaces, and
  shared metric components in `DesignTokens.swift`.
- [x] Apply the design system across navigation, workout analysis, comparison,
  replay, empty states, map overlays, and export presentation.
- [x] Keep Overview, Charts, Splits, Segments, Compare, Import, Delete, and Export
  connected to the existing application state and services.
- [x] Add keyboard paths, focus participation, accessible chart seeking,
  destructive confirmation, and Reduce Motion handling.
- [x] Cache chart data, precompute active split identity, preserve the final
  split highlight, and isolate static workout content from replay ticks.
- [x] Preserve the macOS-only Studio and Platform package boundary and remove
  unsupported UIKit and iOS product claims.
- [x] Reconcile `DESIGN.md`, the Kiro requirements and design, and the final PR
  metadata with the implemented scope.
- [x] Run warning-clean SwiftPM Core, Platform, and full-stack tests.
- [x] Run warning-clean Xcode workspace tests and `git diff --check`.
- [x] Complete a fresh packaged-app HIG and workflow pass for all primary modes
  and comparison using bundled or synthetic data.
- [x] Verify the exact-head GitHub checks and review-thread state.
