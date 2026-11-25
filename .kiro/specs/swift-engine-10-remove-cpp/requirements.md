# Remove the C++ engine and all interoperability: requirements

1. The package contains no C or C++ target. `RunPlayEngineCpp/`, its SwiftPM
   test harness, `scripts/run-cpp-engine-tests.sh` and the `validate-cpp-*`
   scripts are deleted.
2. No target enables C++ interoperability, and the package sets no C++
   language standard. `Tests/PackageConsumerSmoke` builds and runs without it.
3. `RunPlayCore/Sources/Interop/` no longer exists. `NativeCallObserver` is
   `EngineCallObserver`; `RunPlayEngineInfo` is removed; `RunPlayEngineLimits`
   reads only the Swift engine.
4. Production behaviour does not change: no `RunPlayCore` public API, `Codable`
   shape, persisted format, or engine output changes. Every golden digest test
   keeps its pinned constant.
5. The differential (Swift against C++) tests are deleted. Each kernel keeps
   its golden digest test in `<Kernel>GoldenTests.swift`, computed from the
   Swift engine over the same corpus and byte order.
6. `EngineCallCardinalityTests` stays green: one engine call per production
   operation.
7. CI has no C++ step. The Linux sanitizers leg runs the engine tests under
   AddressSanitizer. The engine boundary validator also rejects a C++
   interoperability setting, and checks the macOS target graph on every macOS
   run.
8. The Linux test floor is lowered deliberately, with the deleted tests named
   in the PR body.
9. `AGENTS.md`, `README.md`, `docs/` and `.kiro/steering` describe the Swift
   engine. The two `docs/cpp-engine-*` documents become `docs/engine.md`.
10. The Swift oracles and the oracle benchmarks stay; the next PR retires them.
