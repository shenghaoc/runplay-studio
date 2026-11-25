# Retire the Swift oracles: tasks

1. Delete the oracle files and the oracle-only parity test file.
2. Classify every `git grep -i oracle` hit in Swift sources, tests and scripts;
   delete oracle-only tests and trim the oracle comparison from the rest.
3. Remove the oracle side from the benchmarks; add `BenchmarkBaselineLine` and
   print one baseline line per case.
4. Update the runner script headers and output selection.
5. Update `docs/engine.md`, `docs/architecture.md`, `docs/phase-plan.md`, and
   the one Core source comment that names an oracle.
6. Re-derive the Linux test floor from the deleted XCTest count.
7. Verify: the Core and engine suites warning-clean, the Linux gate, the
   boundary validator, a release build of the tests, and each changed runner
   once.
