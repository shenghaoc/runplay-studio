# RunPlay Studio — Agent Workflow

Operational reference for agents working in this repository. Policy is in
`AGENTS.md`; this document covers the *how* of common workflows.

## Startup Checklist

```bash
git status --short          # never discard unexplained changes
git fetch origin
git log --oneline -5        # confirm current branch and merge base
```

Read only the detailed references relevant to the task before editing anything.

## Branch and Worktree Setup

One task = one branch + one worktree + one PR.

```bash
git fetch origin
git worktree add -b <type>/<short-task> ../runplay-<task> origin/main
cd ../runplay-<task>
```

Naming conventions: `feat/`, `fix/`, `docs/`, `refactor/`, `ci/`, `chore/`.

## Verification

Always use `scripts/verify.sh` — the same interface CI uses.

```bash
./scripts/verify.sh core          # RunPlayCore changes (Linux-compatible)
./scripts/verify.sh platform      # RunPlayPlatform changes (macOS only)
./scripts/verify.sh full          # Studio, package, CI, or cross-layer changes
git diff --check                  # whitespace check before commit
```

Run the **narrowest** relevant gate first. Run `full` when touching shared
types, `Package.swift`, CI workflows, or anything that crosses module
boundaries.

## Committing Safely

```bash
git status --short
git diff --cached --name-status   # after staging, before committing
git add <explicit paths>          # never git add -A when private data may be present
```

Never commit real workout data. Check `local-workouts/`, `private-workouts/`,
and any `activity_*.tcx` / `activity_*.fit` files are untracked before
committing.

## Opening a PR

Open a draft PR early with the body filled in using
`.github/pull_request_template.md`. The body should state:

- Objective and scope
- Explicit non-goals
- Validation commands actually run and their results
- Remaining manual checks from `docs/manual-testing.md`
- Dependent or conflicting PRs

## Taking Over an Existing PR

1. Read the PR body and all review comments
2. Inspect `git log --oneline origin/main..HEAD` on the branch
3. Check CI status
4. Update the PR body with your intent before changing scope

## Parallel Work

Declare which files or subsystem your PR touches. Serialize changes to:
`AGENTS.md`, `Package.swift`, CI workflows, `AppState`, shared architecture
docs, and `.kiro/steering/` files. Do not edit these concurrently with another
open PR that also touches them.

## Manual Testing

GUI changes require the relevant checklist in `docs/manual-testing.md`. Do not
claim support for a GUI behavior without running the checklist and recording the
result honestly.

## Cleanup After Merge

Remove only your own worktree and local branch:

```bash
git worktree remove ../runplay-<task>
git branch -d <type>/<short-task>
```
