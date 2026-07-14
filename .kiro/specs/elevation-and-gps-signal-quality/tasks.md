# Implementation Tasks

- [x] Add `RouteQualityPolicy`, `RouteQualityProcessor`, result diagnostics,
  distance-source provenance, conservative coordinate cleanup, implicit gap
  inference, source-speed validation, and compatibility sanitizer delegation.
- [x] Add the aligned distance-domain `ElevationProfile`, isolated altitude
  rejection, missing/segment gap preservation, and threshold-confirmed
  gain/loss prefixes with cancellation support.
- [x] Add `WorkoutAnalysisContext` and route summary, splits, timeline elevation,
  notable climb/descent, replay metrics, comparison, charts, route projection,
  route colouring, and exports through the corrected profile.
- [x] Persist normalization version, diagnostics, warnings, and distance
  provenance; migrate normalization before analysis while preserving usable
  in-memory data on an atomic rewrite failure.
- [x] Keep interactive cancellation distinct from parsing failure and prevent a
  cancelled import from entering the persistence transaction.
- [x] Synchronize architecture, data-model, import-format, manual-testing, and
  requirements/design documentation without claiming a manual pass.
- [x] Reconcile synthetic coordinate, elevation, downstream, migration,
  cancellation, malformed-value, and 100,000-point tests with the final APIs.
- [x] Run focused route-quality/profile/consumer/migration suites plus the
  warning-clean Core, full SwiftPM, Xcode package-scheme, and packaged-app gates.
- [ ] Perform only the available unchecked route-quality GUI scenarios and
  report exactly what was and was not observed.
- [x] Reconcile the final diff, commit logical units, push the feature branch,
  and open a draft pull request with architecture, policies, tests, exact gates,
  manual status, and limitations.
