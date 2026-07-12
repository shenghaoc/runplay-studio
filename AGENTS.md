# AGENTS.md — RunPlay Studio

RunPlay Studio is a native macOS application for local, post-run GPS workout
visualization, replay, analysis, comparison, and export. It is not a live
tracker, cloud service, social network, web app, or AI product.

This is the canonical operating contract for every coding agent. It supersedes
historical rapid-prototyping prompts that instructed agents to work directly on
`main` or leave transient handoff status in committed documentation.

## Instruction Hierarchy

1. Source code, tests, `Package.swift`, and CI workflows are executable truth.
2. This root `AGENTS.md` defines repository operating policy.
3. Linked documentation provides detailed reference material.
4. Tool entrypoints—including Claude, Gemini, Copilot, and Kiro steering—must
   defer to this file and must not duplicate or override policy.
5. `.jules/` files are advisory historical learnings. `.kiro/specs/` files are
   task artifacts. Neither overrides this file or executable truth.

When prose conflicts with implementation, inspect the implementation, tests,
and CI. Correct durable documentation drift in the same change when relevant;
do not silently follow stale prose.

## Agent Startup

Before editing:

1. Read this file and only the detailed references relevant to the task.
2. Run `git status --short`; never discard unexplained user or agent changes.
3. Fetch `origin`, confirm the current branch, merge base, and assigned PR.
4. Inspect the affected implementation and tests before proposing a change.
5. Run the narrowest relevant baseline verification command.
6. Open or update a draft PR with its scope and explicit non-goals before
   implementation work becomes broad.

## Branch, Worktree, And PR Rules

- **Never commit directly to `main` and never rewrite or force-push it.**
- One task equals one branch, one worktree, and one PR. Do not let agents share
  a checkout or branch.
- Start new work from current `origin/main`; rebase only the branch you own.
- Do not rebase, reset, amend, clean, force-push, merge, or delete another
  agent's branch or worktree without the owner's explicit direction.
- Make small logical commits and push useful checkpoints to the feature branch.
- Do not create handoff-only commits or store current commit hashes in committed
  documentation. `git log`, the live PR, and CI are the current-state sources.
- PR descriptions and comments are task handoffs. Record objective, scope,
  non-goals, validation actually run, and remaining manual checks there.

## Parallel-Agent Safety

- Each PR must declare its intended files or subsystem. Avoid unrelated nearby
  cleanup.
- Serialize changes to shared coordination files: `AGENTS.md`, `Package.swift`,
  CI workflows, `AppState`, shared architecture documents, and Kiro steering.
- Do not overwrite unexplained changes or resurrect commits removed by a history
  cleanup.
- After rebasing onto updated `main`, rerun the relevant verification suite.

The detailed workflow, safe takeover procedure, and cleanup steps are in
[docs/agent-workflow.md](docs/agent-workflow.md).

## Architecture Boundaries

Dependency direction is `RunPlayStudio → RunPlayPlatform → RunPlayCore`.
Reverse dependencies are forbidden.

- **RunPlayCore** is cross-platform Foundation logic with conditional
  `FoundationXML`; it must not import UI, map, graphics, Core Location, or
  Combine frameworks. Use `GeoDistance`, not `CLLocation`, for core distance.
- **RunPlayPlatform** contains macOS non-SwiftUI adapters for SceneKit, AppKit,
  MapKit, and non-UI Combine. It must not depend on `RunPlayStudio`.
- **RunPlayStudio** owns SwiftUI, Charts, app lifecycle, GUI state, and UI
  export.

See [docs/architecture.md](docs/architecture.md) and
[Package.swift](Package.swift) for the live architecture and package graph.

## Project Invariants

- Do not add a third-party dependency without explicit owner approval and
  license review.
- Keep the app local-only. Do not add an app-operated backend, accounts,
  telemetry, analytics, cloud sync, or AI API without an explicit product
  decision.
- Never commit real workout data, screenshots, or exports. Private dogfood
  files belong only in ignored `local-workouts/` or `private-workouts/` paths;
  committed fixtures and demo assets must be synthetic or anonymized.
- Use explicit `git add <path>` for changes that could include local data.
  Before committing, inspect `git status --short` and
  `git diff --cached --name-status`.

See [docs/private-data.md](docs/private-data.md) and
[docs/privacy.md](docs/privacy.md) for detail.

## Change Discipline

- Make the smallest coherent change that satisfies the assigned task.
- Preserve public APIs unless the task explicitly changes them.
- Add or update focused tests for behavior changes.
- Do not claim GUI, format, platform, or workflow support without verification;
  report the actual command or manual boundary instead.
- Keep documentation tied to durable behavior, never transient branch status.

## Kiro And Durable Learnings

Kiro is a supported first-class environment. Root `AGENTS.md` is canonical;
`.kiro/steering/` supplies scoped Kiro context through its declared inclusion
modes and live file references. Do not add Kiro hooks in this repository.

Kiro specs are task artifacts: one spec belongs to one branch and one PR. Keep
requirements, design, and tasks aligned with the PR scope. Checked task boxes
do not prove completion; tests and CI do. Specs must not contain private data,
secrets, transient commit hashes, or repository-wide handoff status. Parallel
spec tasks must not edit the same shared files concurrently.

`.jules/` is the single lowercase home for reusable learnings: `bolt.md` for
performance, `palette.md` for accessibility, and `sentinel.md` for security.
Add a concise dated entry only for a concrete reusable finding and its
preventive action. Do not use it for task status, speculative advice, or copied
policy. See [.jules/README.md](.jules/README.md).

## Validation

Use the shared verification interface so local work and CI stay aligned:

```bash
./scripts/verify.sh agent-config  # Agent, Kiro, and documentation configuration
./scripts/verify.sh core          # RunPlayCore changes
./scripts/verify.sh platform      # RunPlayPlatform changes on macOS
./scripts/verify.sh full          # Studio, package, CI, or cross-layer changes
git diff --check
```

GUI changes additionally require the relevant honest manual check in
[docs/manual-testing.md](docs/manual-testing.md).

## Detailed References

- [README.md](README.md) — product overview and local build entrypoint
- [docs/architecture.md](docs/architecture.md) — data flow and abstractions
- [docs/import-formats.md](docs/import-formats.md) — supported formats and limits
- [docs/manual-testing.md](docs/manual-testing.md) — GUI and release checks
- [docs/private-data.md](docs/private-data.md) — private-data hygiene
- [docs/phase-plan.md](docs/phase-plan.md) — planning context, not executable truth
- [docs/agent-workflow.md](docs/agent-workflow.md) — detailed agent procedure
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — enforced CI behavior
