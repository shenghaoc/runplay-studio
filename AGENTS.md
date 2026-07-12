# AGENTS.md — RunPlay Studio

This is the canonical repository instruction file for every coding agent. Keep
it concise and durable. `CLAUDE.md`, `GEMINI.md`, and
`.github/copilot-instructions.md` are adapters only and must not duplicate or
override it.

## Source Of Truth

- Source code, tests, CI workflows, and `Package.swift` are executable truth.
  When they disagree with prose, follow the executable source and correct the
  documentation in the same change when appropriate.
- Use the focused document for detailed procedure: [architecture](docs/architecture.md),
  [manual testing](docs/manual-testing.md), [import formats](docs/import-formats.md),
  [privacy](docs/privacy.md), [private-data policy](docs/private-data.md), and
  [agent workflow](docs/agent-workflow.md).
- Do not use root instructions or committed documentation to record a branch's
  current commit, PR state, pending handoff, or latest verification result.
  Use `git log`, the live pull request, and CI for that transient state.

## Branch And PR Workflow

- **Never commit directly to `main`.** Create a focused branch from current
  `origin/main`, make small reviewable commits, and open a PR.
- Each parallel agent needs its own branch, worktree, and PR. Do not share a
  worktree, write to another agent's branch, or mix unrelated changes.
- Keep PR descriptions and comments as task handoffs: state the objective,
  scope, validation, and remaining questions there. Do not make hash-only or
  status-only documentation commits.

## Project Guardrails

- Keep the package free of third-party dependencies unless an explicit product
  decision approves one.
- RunPlay Studio is local-only. Do not add app-operated cloud services,
  accounts, telemetry, analytics, or AI APIs without an explicit product
  decision.
- Never commit real workout data. Private files belong in the gitignored
  `local-workouts/` or `private-workouts/` directories; committed fixtures,
  demo assets, and exports must be synthetic or anonymized.

## Architecture Boundaries

Dependency flow is `RunPlayStudio → RunPlayPlatform → RunPlayCore`; reverse
dependencies are forbidden.

- **RunPlayCore** is cross-platform Foundation logic. It may conditionally use
  `FoundationXML`; it must not import UI, map, graphics, Core Location, or
  Combine frameworks. Use `GeoDistance`, not `CLLocation`, for core distance
  calculations.
- **RunPlayPlatform** is macOS non-UI code for SceneKit, AppKit, MapKit, and
  non-UI Combine adapters. It must not depend on `RunPlayStudio`.
- **RunPlayStudio** owns SwiftUI, Charts, app lifecycle, and `@MainActor` UI
  state.
- The package uses Swift 6 language mode, tools version 6.3, and macOS 26.
  `Package.swift` keeps Core in the Linux package graph and gates macOS layers
  with `#if os(macOS)`.

## Validation

Run the narrowest relevant gate first, then the full package gate for changes
that touch shared, package, CI, or integration behavior. CI treats warnings as
errors; use the same standard locally.

```bash
git diff --check
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
```

For Core-only work, use `swift build --target RunPlayCore` and
`swift test --filter RunPlayCoreTests`. Full commands and manual QA procedures
are in [docs/agent-workflow.md](docs/agent-workflow.md) and
[docs/manual-testing.md](docs/manual-testing.md).

## Durable Learnings

`.jules/` is the single lowercase home for durable, reusable learnings:
`bolt.md` for performance, `palette.md` for accessibility, and `sentinel.md`
for security. Add a concise dated learning only when a completed change yields
a reusable rule; include the prevention or action. Do not use these files for
PR status, temporary task notes, or duplicated repository instructions.
