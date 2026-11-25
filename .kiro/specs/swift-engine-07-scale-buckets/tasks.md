# Scale and bucket migration tasks

1. Port the kernel and the eight native case groups with their names and literals.
2. Compare Swift and C++ on a seeded corpus: bit-exact except ±0 ties, numeric there.
3. Capture the golden digest from the Swift kernel (one value for all platforms) and
   pin the Swift result of the 32-sample witness in its own test.
4. Switch the production adapter and confine the C++ call to
   `RouteMetricScaleBucketDifferentialTests.swift`.
5. Run the validators, Core and Engine suites, the Linux gate, and the complete-path
   release benchmark (including the 1M-point probe) on macOS and in the pinned image.
