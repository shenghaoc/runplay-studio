# Requirements — C++23 Route-Metric Scale and Buckets

## Objective

Migrate only numeric route-metric scale construction, normalization, bucket
assignment, and numeric diagnostics into one allocation-free C++23 bulk call
per non-solid profile finalization.

## Ownership

- Swift retains raw pace, heart-rate, and corrected-elevation extraction.
- Swift retains distance-domain smoothing.
- Swift retains localized labels, `DisplayFormatter`, scale direction, public
  models, total-distance and availability policy, probing, caching,
  cancellation orchestration, Platform map-line work, UI, and persistence.
- C++ receives one metric/weight sample per Swift `RawInterval` and returns one
  numeric assignment per input interval.
- Swift owns input and output buffers. C++ borrows them synchronously, retains
  no pointer, and performs no callback.

## Contract

- One native call occurs per non-solid profile finalization; solid mode makes
  no call. No call occurs per interval, quantile, bucket, line, or route point.
- Output count equals input interval count.
- After complete validation, the caller-owned output buffer is the native
  route-sized sorting workspace. No route-sized C++ heap allocation is allowed.
- Every failure before mutation leaves the output byte-for-byte unchanged, and
  no error may occur after mutation begins.
- Exact pre-migration profile parity is mandatory, including custom policies,
  numeric edge cases, labels, diagnostics, cancellation, and product-visible
  callers.
- There is no schema, UI, importer, analysis-version, normalization-version,
  cache, smoothing, or map-line semantic change.

## Roadmap

After this phase, the next phase is mandatory final portable-core cleanup
unless new evidence reveals a concrete product-visible blocker. Remaining
phase count becomes minimum 1, expected 1, and maximum reasonable 2 only when
a targeted Swift optimization is justified by evidence.
