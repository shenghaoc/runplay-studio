# Tasks: C++23 Route Value Boundary

- [x] Define `RouteInputSample`, optional aliases, status, and
  `RouteBatchInspection` in public C++ headers with standard-layout /
  copy-constructible asserts
- [x] Implement `inspect_route_batch` with null/empty/limit handling, optional
  counts, segment transitions, and deterministic field digest
- [x] Include route interop from the engine umbrella header without exposing
  `std::vector` on the public surface
- [x] Add internal `RunPlayRouteBridge` Swift adapter that owns a contiguous
  buffer, performs one bulk call, and returns pure Swift values only
- [x] Add independent native C++ route interop tests (empty, invalid, limit,
  complete digest constant, segments, 100k heap batch)
- [x] Add independent Swift parity oracle tests (field fidelity, optionals,
  segments, non-finite/signed-zero bits, 100k route)
- [x] Extend native test harness (`TestMain`, `TestSupport`, multi-source
  `run-cpp-engine-tests.sh`)
- [x] Harden boundary validators (public AST, Swift import lexer, package graph,
  route signature checks)
- [x] Update AGENTS.md, README, architecture, and data-model docs to the
  route-value contract and explicit non-goals
- [x] Confirm no production call site uses the route bridge
- [x] Align Kiro spec (this folder) with the final implementation
- [x] Run warning-clean verification matrix listed in the PR body
