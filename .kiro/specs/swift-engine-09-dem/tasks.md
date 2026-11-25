# DEM tile planning and sampling Swift port tasks

1. Port both kernels and the twenty-one native cases with their names.
2. Compare the kernels exactly against C++ on a seeded corpus and pin the C++-derived
   digest per platform (macOS now, Linux x86_64 once hosted CI reports it).
3. Switch the production adapter and confine the C++ calls, one per kernel, to
   `DemElevationDifferentialTests.swift`.
4. Run the validators, Core and Engine suites, the Linux gate and the complete-path
   release benchmark, including the one-million-point probe.
