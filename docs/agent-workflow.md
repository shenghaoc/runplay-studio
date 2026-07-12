# RunPlay Studio — Agent Workflow

This document contains the durable procedure for coding agents. It complements
[AGENTS.md](../AGENTS.md), which is the concise canonical instruction file.
Use pull-request descriptions and comments—not committed documentation—for
task-specific handoffs, current branch state, and verification results.

## Start Safely

Begin every task by checking the exact repository state. For a pull-request
task, use its number instead of assuming the current branch is correct.

```bash
git status --short
git fetch origin
gh pr checkout <number>
git log --oneline -10
git diff origin/main...HEAD --stat
```

Read the affected code, tests, and the relevant focused documentation before
editing. Treat `Package.swift`, source, tests, and CI as authoritative if they
conflict with prose.

## Parallel Agent Isolation

One agent owns one branch and one worktree. Start from fresh `origin/main`
unless continuing the exact pull request assigned to that agent.

```bash
git fetch origin
git worktree add -b <type>/<short-task> ../runplay-studio-<task> origin/main
cd ../runplay-studio-<task>
```

- Never share a working tree or branch with another agent.
- Do not reset, rebase, force-push, or clean files owned by another agent.
- Keep each PR focused on one concern. Use a new branch and worktree for an
  independent follow-up.
- Before publishing a rebased branch, confirm its merge base and use
  `git push --force-with-lease`, never an unguarded force push.

## Find The Right Detail

| Need | Source |
| --- | --- |
| Module ownership, data flow, and framework boundaries | [Architecture](architecture.md) |
| Import support and format limitations | [Import formats](import-formats.md) |
| GUI and release-facing checks | [Manual testing](manual-testing.md) |
| Local-only product policy | [Privacy](privacy.md) and [private-data policy](private-data.md) |
| Product sequencing | [Phase plan](phase-plan.md) |

Do not copy detailed implementation procedures into `AGENTS.md` or vendor
adapter files. Link to the focused document instead.

## Change And Validate

Choose validation based on the changed surface. Start narrow, then run the
full warning-clean package gate when shared behavior, package configuration,
CI, or cross-layer integration is affected.

```bash
# Core-only work
swift build --target RunPlayCore -Xswiftc -warnings-as-errors
swift test --filter RunPlayCoreTests -Xswiftc -warnings-as-errors

# Platform-only work (macOS)
swift build --target RunPlayPlatform -Xswiftc -warnings-as-errors
swift test --filter RunPlayPlatformTests -Xswiftc -warnings-as-errors

# Full package gate (macOS)
git diff --check
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
```

Run the applicable manual checklist for user-visible changes. Do not claim GUI
verification without performing it; report the command and the exact boundary
instead.

## Handoff And Publish

Use the PR body as the durable task handoff for that PR:

- objective and explicit non-goals;
- changed files and behavior;
- validation actually run and its result;
- known limitations, follow-up work, or manual checks still needed.

Use PR comments for interim coordination. Do not add a committed document only
to record a commit hash, a check result, a branch name, or temporary task
status. `git log`, the live PR, and CI are the current-state sources.

Before requesting review, inspect the final diff, confirm the PR points at the
intended head, and ensure the description matches the actual change.

## Record Reusable Learnings

Keep reusable learnings under `.jules/`:

- `bolt.md` — performance and scalability;
- `palette.md` — accessibility and interaction design;
- `sentinel.md` — security and data safety.

Add an entry only after a completed change reveals a durable rule. Use a date,
the lesson, and the concrete prevention or action. Do not copy `AGENTS.md`,
restate project architecture, or leave task-status notes there.
