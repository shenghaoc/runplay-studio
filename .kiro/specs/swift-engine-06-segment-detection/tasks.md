# Segment-detection Swift port tasks

1. Port the native kernel and native case names.
2. Compare raw candidate fields and both counters against the unchanged C++ kernels.
3. Pin the native macOS corpus digest now and the hosted native x86_64 Linux digest once CI reports it; the golden test is skipped, not passed, until then.
4. Keep the Core adapter cutover and the confinement of C++ calls to `SegmentDetectionDifferentialTests.swift` separate.
5. Run exact-head validators, test suites, and 100K/1M release probes.
