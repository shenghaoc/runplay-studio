# Retire the Swift oracles: design

## Why the oracles can go

During the migration each kernel had two references: the C++ kernel, and a
transcription of the pre-migration Swift implementation in the test target.
The previous PR removed the C++ kernel and kept one golden digest per kernel,
captured while a differential test proved the Swift and C++ outputs equal.
The digest now pins the complete output of every kernel. An oracle comparison
adds no reference the digest does not already hold, and the oracles are
roughly 3,000 lines of test code to maintain.

## Tests

Each oracle hit is classified:

- **Oracle only.** The test compares the production path with an oracle and
  asserts nothing else. It is deleted with its helpers and generators.
- **Oracle plus behaviour.** The test also pins behaviour directly: an
  availability reason, a candidate distance, a bucket index, an outcome
  category, a fixture-coverage guard. The oracle call is removed; the direct
  assertions stay. A helper that ran both sides now runs the production side
  only and is renamed to say so.
- **Transitive expected values.** Where a test asserted the oracle against
  fixed values and the bridge against the oracle
  (`RouteMetricScaleBucketCompatibilityTests`), the bridge is asserted against
  the fixed values directly.
- **Input-mapping property.** `ElevationProfileDEMSourceTests` compared a DEM
  route with the oracle on a DEM-free mapped copy. It now compares the
  production build of the DEM route with the production build of the mapped
  copy, which is the same property without the oracle.

`AppleHealthDateParserTests` uses a `DateFormatter` as an independent date
oracle; it is not a migration oracle and is unchanged. Golden-test comments
that record where a constant was captured stay, because they are provenance.

## Benchmarks

The oracle side and its ratio are removed. Every benchmark that changes
prints its cases through `BenchmarkBaselineLine` (test target only):

```text
<Benchmark> <case> <count>=<value> ... iterations=<n> swift_ms=<median> [swift_max_ms=<maximum>]
```

The class name prefix makes each benchmark's lines greppable, and resident
memory uses the same prefix with `bytes=`. Where a benchmark asserted parity
with an oracle, it now asserts only that repeated runs give identical results.
The heatmap coverage benchmark prints its product-limit probe inside its
report markers, so the runner no longer needs a separate range for it.

## Runners

The filters and environment do not change. The DTW, route-quality and segment
runners select the header and baseline lines by prefix instead of a line
range that ended on a merge-gate line.
