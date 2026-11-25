# Remove the C++ engine and all interoperability: tasks

1. Delete `RunPlayEngineCpp/`, the C++ scripts and the manifest's C++ settings.
2. Remove `RunPlayCore/Sources/Interop/`; rename the call observer; move the
   engine limits.
3. Convert each differential test to a golden digest test; delete the recorded
   unrepresentable C++ cases; make the benchmarks Swift-only.
4. Update the boundary validator, the lane selector, CI and the release
   manifest.
5. Rewrite `AGENTS.md` (architecture, Swift engine policy, lanes, validation),
   `README.md`, `docs/architecture.md`, `docs/data-model.md`,
   `docs/portable-core-ios-readiness.md`, `.kiro/steering`; merge the two
   engine documents into `docs/engine.md`.
6. Re-derive the Linux test floor.
7. Verify: validators, the engine and Core suites, the Linux gate, the engine
   tests under AddressSanitizer, the consumer smoke package, and a release
   build of the tests.
