# Private Workout Data Policy

RunPlay Studio is local-only, but real workout files can still expose personal
routes, timestamps, heart-rate data, and home or work locations. Treat any
real-world GPX, TCX, FIT, or JSON activity file as private unless it was
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

- Personal GPX, TCX, FIT, or JSON workout exports
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
