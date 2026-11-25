# Personal heatmap coverage Swift port tasks

1. Port the kernel and the six native case groups with their names and literals.
2. Compare Swift and C++ exactly on a seeded corpus; pin the C++-derived digest per
   platform (macOS now, Linux x86_64 once hosted CI reports it).
3. Switch the production adapter, delete the capacity-retry loop and rework its
   profiling types and tests, and confine the C++ call to
   `PersonalHeatmapCoverageDifferentialTests.swift`.
4. Run the validators, Core and Engine suites, the Linux gate and the complete-path
   release benchmark, including the one-million-point probe.
