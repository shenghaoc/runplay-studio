# Remove the C++ engine and all interoperability: design

## Manifest

`Package.swift` drops the `RunPlayEngineCpp` target, `RunPlayEngineCppTests`,
`engineCppSettings`, `cxxInteropSettings` and `cxxLanguageStandard`.
`RunPlayCore` depends on `RunPlayEngine` only. Every Swift target keeps
`strictWarnings`; the engine keeps strict memory safety.

## Core

The remaining `Interop/` files were either C++ parity adapters with no
production caller (`RunPlayEngineBridge`, `RunPlayGeodesyBridge`,
`RunPlayRouteBridge`, `RunPlayRouteInputBuffer`) or Swift-only values that move
to `Sources/Engine` (`RunPlayEngineLimits`, `EngineCallObserver`). Adapter
type names are unchanged, so no service call site changes.

## Tests

A differential test proved, per kernel, that the Swift and C++ outputs are
equal bit for bit, and pinned the digest of that output per CI platform. The
digest is the part that survives: `<Kernel>GoldenTests.swift` keeps the corpus
generator, the Swift digest and the pinned constants, and drops the C++
marshalling and comparison. The geodesy golden asserted its constant against
the C++ digest; it now hashes the Swift `EngineGeodesy` results over the same
pairs, count prefixes and seed, and the constant is unchanged.

C++ test cases that only a pointer boundary could express were recorded in the
engine tests as placeholders or comments. They are deleted; the PR body lists
each one.

Benchmarks lose their C++ side and their Swift/C++ ratio gate and report
absolute Swift timings. Their names, filters and environment gates are
unchanged, so the runner scripts keep working.

## Validators and CI

`validate-swift-engine-boundaries.py` authorizes an engine import in
`*GoldenTests.swift` instead of `*DifferentialTests.swift`, rejects a C++
interoperability setting or a C/C++ language standard in the manifest, and
gains `--graph-only` for the macOS lane. `validate-swift-engine-imports.py`
validated imports of the C++ module and is deleted with it.

The Linux sanitizers leg runs
`swift test --sanitize=address --filter RunPlayEngineTests` with LeakSanitizer
on. corelibs XCTest keeps its test-discovery tables and suite setup until the
process exits, so `scripts/lsan-xctest-discovery.supp` suppresses exactly
those frames; a probe test that leaks a retain cycle still fails the run. The
macOS lane
builds `RunPlayEngine` where it built `RunPlayEngineCpp`.
`scripts/ci-select-lanes.sh` drops `RunPlayEngineCpp/*` from the Core-level
case; an unknown `RunPlay*` directory still selects everything.

## Release manifest

`scripts/package-release.sh` no longer writes `cpp_standard`: the product
contains no C++.
