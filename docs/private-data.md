# Private Workout Data Policy

RunPlay Studio keeps all workout data on your Mac, but real workout files can still expose personal
routes, timestamps, heart-rate data, and home or work locations. Treat any
real-world GPX, TCX, FIT, JSON activity file, or Apple Health export archive as private unless it was
explicitly synthesized or anonymized for public use.

## Local Dogfood Files

Put private workout files in ignored local-only paths:

- `local-workouts/`
- `private-workouts/`

The repository also ignores common local activity filename patterns such as
`*.local.gpx`, `*.local.tcx`, `*.local.fit`, `activity_*.tcx`, and
`activity_*.fit`.

## What Never Goes Into Git

Do not commit:

- Personal GPX, TCX, FIT, JSON or Apple Health `export.zip`/`export.xml` files
- Screenshots showing private routes or maps
- Exported JSON, CSV, or PNG files generated from private workouts
- Derived route summaries that reveal private locations, timestamps, or health
  metrics

Before committing, run:

```bash
git status --short
git diff --cached --name-status
```

Stage files explicitly, for example:

```bash
git add README.md docs/manual-testing.md
```

Do not use `git add -A` when private workout files are present.

## Public Fixtures And Demo Assets

Committed fixtures and demo exports must be synthetic or anonymized:

- Synthetic test fixtures belong under `RunPlayStudio/Resources/fixtures/`.
- Public demo screenshots and exports belong under `docs/assets/`.
- Demo assets must not be generated from private real-world activity files.
- If a fixture is derived from real activity data, strip or alter locations,
  timestamps, titles, identifiers, and health metrics before committing it.

When in doubt, keep the file local and document the manual test instead of
committing the artifact.

## Apple Health acceptance checks

A Health export includes sensitive data far beyond running. Keep it only in an
ignored private-data directory. Structural probes must stream archive contents
without copying them into fixtures; retain element/attribute names, enum-like
type identifiers and counts only. Never log private values or take screenshots.
Synthetic generators use independently invented values, never values copied
from a real export (including partial samples).

Acceptance harnesses belong outside the repository. Show their source before
running them, use the real user cache location and a throwaway workout library,
and delete the harness/library afterwards. The production scan removes its
private temporary XML. Review count-only results independently of the GUI pass;
use synthetic runs for shareable GUI evidence.
