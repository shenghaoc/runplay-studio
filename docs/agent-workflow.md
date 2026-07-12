# RunPlay Studio — Agent Workflow

This document is the durable procedure behind the concise canonical
[AGENTS.md](../AGENTS.md). Use the live PR, `git log`, and CI for task-specific
handoff and current verification state; do not commit status-only documents.

## Start A Task

Inspect the exact assigned branch or PR before editing:

```bash
git status --short
git fetch origin
gh pr checkout <number>
git log --oneline -10
git diff origin/main...HEAD --stat
```

Read the affected source, tests, and focused references before changing code.
Run the appropriate `./scripts/verify.sh` mode before and after meaningful
changes. If the worktree is not clean, preserve unexplained changes and clarify
ownership instead of discarding them.

## Isolate Parallel Work

Create a dedicated worktree and branch from fresh `origin/main` for a new task:

```bash
git fetch origin
git worktree add -b <type>/<short-task> ../runplay-<task> origin/main
cd ../runplay-<task>
```

- One task uses one branch, one worktree, and one PR.
- Open a draft PR early. Declare scope, non-goals, affected files or layers,
  dependent PRs, and manual verification needs.
- Keep shared coordination files to one active owner at a time: `AGENTS.md`,
  `Package.swift`, CI, `AppState`, shared architecture docs, and Kiro steering.
- Do not reset, rebase, force-push, amend, delete, or clean work owned by
  another agent. Rebase only your own branch; use `--force-with-lease` only
  after confirming its merge base.
- Do not opportunistically refactor outside the requested scope.

## Change And Validate

Use the shared verification interface:

```bash
./scripts/verify.sh core
./scripts/verify.sh platform
./scripts/verify.sh full
git diff --check
```

Run the narrowest mode first. Use `full` for Studio, package, CI, or cross-layer
changes. Run [manual testing](manual-testing.md) for user-visible changes, and
state precisely what was and was not manually verified.

Focused references:

| Need | Source |
| --- | --- |
| Product purpose and local build | [README](../README.md) |
| Module boundaries and data flow | [Architecture](architecture.md) |
| Import behavior and limits | [Import formats](import-formats.md) |
| Private-data hygiene | [Private-data policy](private-data.md) |
| Planning context | [Phase plan](phase-plan.md) |

## Kiro

Kiro automatically loads root `AGENTS.md`. Its foundational steering files use
scoped inclusion to provide Kiro-specific routing and live workspace references;
they are not a second policy system.

Specs are task artifacts, not canonical policy. One spec belongs to one branch and one PR; keep its requirements, design, and tasks aligned with that PR's scope. Do not create or update a task spec on `main`, use a spec to coordinate unrelated PRs, or put private data, secrets, transient hashes, or handoff status in it. Checked task boxes do not prove completion—tests and CI do. Parallel Kiro tasks must not modify the same shared files concurrently.

## Handoff, Takeover, And Cleanup

Use the PR body as the task handoff. It must include:

- objective, explicit non-goals, and affected layers;
- changed behavior and files;
- exact validation run and its outcome;
- manual checks, risks, rollback, and dependent or conflicting PRs.

Use comments for interim coordination. Do not add a committed file only to
record a branch name, commit hash, check result, or temporary status.

Before taking over an existing PR, read its body and comments, inspect the live
head, branch diff, review threads, and CI. Update the PR handoff before changing
scope. After merge, remove only your own worktree and local branch when no
longer needed; never delete another agent's workspace or branch.

## Durable Learnings

`.jules/` holds curated reusable learnings: `bolt.md` for performance,
`palette.md` for accessibility, and `sentinel.md` for security. Add only a
concrete lesson with its affected subsystem and prevention. Consolidate
duplicates; do not append task status, copied policy, speculative advice,
private data, secrets, or commit hashes.
