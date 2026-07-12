# Implementation Tasks

- [x] Add a Core-only FIT binary reader, definitions, typed decoded messages,
  source ordering, profile constants, and activity-message retention.
- [x] Implement compressed timestamps, profile-aware base-type decoding,
  enhanced metrics, CRC/structure checks, cancellation, and resource limits.
- [x] Select one running session, protect multi-session association, preserve
  timer route gaps, and apply supplied distance per valid segment.
- [x] Keep FIT imports on the existing native file-importer and asynchronous
  Core import-service path without introducing a duplicate UI system.
- [x] Add parser, decoder, sanitizer, and importer regression coverage with
  repository-owned synthetic FIT fixtures.
- [x] Align README, format, architecture, manual-test, and agent guidance with
  the supported scope and explicit limitations.
- [x] Update the PR title and body to match the final implementation and exact
  verification evidence.
- [x] Run the complete warning-clean SwiftPM, Xcode macOS, CI-equivalent, and
  packaged-app launch verification matrix.
