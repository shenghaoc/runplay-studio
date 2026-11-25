# Retire the Swift oracles: requirements

1. The test target contains no pre-migration Swift oracle. The seven
   `Swift*Oracle.swift` files and `PreMigrationRouteAlignerOracle.swift` are
   deleted, and so is the in-file coverage oracle in
   `RunPlayPersonalHeatmapCoverageBridgeTests`.
2. A test whose only content is an oracle comparison is deleted. A test that
   also asserts domain behaviour keeps that behaviour and loses only the oracle
   comparison. No non-oracle assertion is weakened.
3. Production behaviour does not change: no file under `RunPlayCore/Sources`
   or `RunPlayEngine/Sources` changes except a comment that names an oracle,
   and no public API, `Codable` shape, persisted format, or engine output
   changes. Every golden digest test keeps its pinned constant.
4. A parity fixture that a remaining test uses stays.
   `SegmentDetectorParityFixtures` stays because
   `SegmentDetectionGoldenTests` runs it.
5. Each benchmark that timed the engine against an oracle times only the
   production Swift path. It prints one stable line per case with absolute
   medians and counts, and no ratio. No benchmark has a ratio gate.
6. The benchmark environment gates (`RUNPLAY_BENCHMARK=1`,
   `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1`, `RUNPLAY_BENCHMARK_MAX_BAND=1`) and
   their skip reasons are unchanged, so every skip reason still matches the
   Linux gate's `ALLOWED_SKIP_PATTERN`.
7. Each `scripts/run-*` runner keeps its `--filter` and environment, and its
   header describes the absolute baseline.
8. `docs/engine.md` states that the oracles are gone, that the benchmarks are
   absolute Swift baselines, and that the 1.10 times gate against C++ was the
   migration gate and is historical. Other durable documents that name the
   oracles or the oracle benchmarks are corrected.
9. The deleted XCTest tests are named in the PR body, and the Linux test
   floor is re-derived from the new count. The floor moves only if the count
   that actually ran falls below it.
