# Tasks — C++23 Route-Metric Scale and Buckets

- [x] Verify live `origin/main`, PR #94 exact-head CI, open PR overlap, branch,
  worktree, and inherited baselines.
- [x] Capture three release product-limit metric-profile baselines outside the
  repository.
- [x] Characterize current Swift custom-policy and numeric edge behavior.
- [x] Add the allocation-free public C++23 bulk boundary and implementation.
- [x] Add native boundary, policy, statistic, normalization, bucket, and large
  fixture coverage under normal, ASan, and UBSan runners.
- [x] Add the pure-Swift Interop result surface and strict native validation.
- [x] Add an independent Swift oracle and at least 1,500 deterministic bridge
  parity fixtures.
- [x] Cut `RouteMetricProfileBuilder.finalizeProfile` over to exactly one native
  call while retaining Swift extraction, smoothing, labels, and public models.
- [x] Add complete profile, Platform, Studio/cache, export, and cancellation
  parity coverage.
- [x] Extend AST and boundary validation without weakening existing checks.
- [x] Add the opt-in release benchmark and pass performance/memory gates.
- [x] Update durable architecture/roadmap documentation.
- [x] Run the complete verification matrix and exact-head CI.
- [x] Preserve the full public Swift `Int` `bucketCount` domain via
  `std::int64_t` policy and output fields (no `Int32` narrowing).
- [x] Preserve positive-infinite valid coverage from extreme finite weights and
  accept individually positive-infinite weights as valid but not
  quantile-eligible; reject NaN and negative weights including `-infinity`.
- [x] Skip both native sorts on guaranteed no-scale inputs discovered during the
  read-only validation pass.
- [x] Refactor compatibility tests to compare oracle, native bridge, and
  production profile builder where representable.
- [x] Add same-machine production A/B benchmark
  (`RouteMetricProductionABBenchmark`) runnable against both `origin/main` and
  PR head without new C++ APIs.
