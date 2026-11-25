# Design: Swift engine scaffold

`RunPlayEngine` is a portable target with no production caller in this stage.
`RunPlayEngineTestSupport` owns the parity primitives and has no engine
dependency. Both engine and Core tests consume it. Future kernel ports
supply their own typed corpus and C++-captured digests. Differential tests
live in `RunPlayCoreTests`; they use `@testable import RunPlayCore` to reach
the Swift adapters and internal C++ bridges, never `import RunPlayEngine`.
Only Core has a production dependency on the engine. The engine unit-test
target also depends on the engine to test kernels in isolation. The digest takes explicit
fixed-width words and encodes their bytes in little-endian order. Bit comparison
compares `bitPattern` directly, including NaN payloads and signed zero.

The import validator checks the engine allow-list and the application layers'
access to it. Both CI platforms run the same validator and build/test the new
target. Linux reuses the existing pinned image; Core's existing test floor and
the package graph above Core do not change. The validator checks the resolved
target graph from SwiftPM's manifest dump, not manifest formatting.
