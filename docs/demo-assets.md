# README Demo Assets

The demo media in the README are rendered, never recorded.
[`scripts/generate-demo-assets.sh`](../scripts/generate-demo-assets.sh)
builds the app in debug and runs it headless with `--demo-assets`. That mode
loads the two bundled synthetic sample runs and calls the same PNG and video
exporters as the export sheets. It opens no window, captures no screen, and
never reads or writes the workout library. Release builds do not contain the
mode.

The data is synthetic:
[`sample_run.json`](../RunPlayStudio/Resources/sample_run.json) ("Morning Park
Run") and
[`comparison_park_run.json`](../RunPlayStudio/Resources/fixtures/comparison_park_run.json)
("Morning Park Progression Run"), the same pair the app loads on first launch.
The Morning Park Run is a steady 5:00/km run, and it states its timing three
ways: timestamps, `elapsedSeconds`, and `speedMetersPerSecond`. The summary card
follows the timestamps, while the Route Replay HUD reads its pace from the speed
field, so an edit must keep all three in agreement. `JSONImporterTests` fails
when they drift apart.

## What Is Generated

| File | Export | Fixed settings |
|------|--------|----------------|
| `demo-summary-{light,dark}.png` | PNG summary card | Metrics-only layout, exactly 1200×1600 at scale 1 |
| `demo-route-replay-{light,dark}.mp4` | Route Replay | 1920×1080, 30 fps, 15 s preset (450 frames), heart-rate route colouring |
| `demo-comparison-replay-{light,dark}.mp4` | Comparison Replay | Same media contract, Route-Aware alignment |
| `demo-route-replay-{light,dark}.gif` | Derived from the Route Replay MP4 | 720×405, 10 fps, 7.5 s loop at 2× playback |
| `demo-route-replay-{light,dark}-poster.png` | First frame of each Route Replay | Still for reduced motion |
| `demo-assets-provenance.txt` | — | The macOS and Xcode versions that made the files |
| `SHA256SUMS` | Checksums of the files above | — |

The summary card uses the metrics-only layout because the map-inclusive one
embeds live Apple Maps imagery, which cannot be rendered the same twice. The
replays need a basemap and always fetch one. That basemap is Apple Maps
imagery, so the README credits Apple Maps next to the GIF. The generator does
not fall back silently. It fails when heart-rate colouring or Route-Aware
alignment is unavailable, when a summary card is not 1200×1600, when the light
and dark cards are byte-identical, or when the bundled runs are not the two
documented workouts with routes.

The settings live in `DemoAssetCatalog`
(`RunPlayStudio/Sources/DemoAssets/DemoAssetGenerator.swift`).

## Running It

```bash
./scripts/generate-demo-assets.sh
```

The output goes to `.build/demo-assets/`, which git ignores. `--output-dir`
picks another directory, resolved from the current directory. Symlinks in
existing ancestors are resolved before any creation or cleanup; only strict
descendants of the repository's real `.build/` are accepted. The script also
refuses a non-empty directory it did not create. `--skip-build` reuses the
existing debug build.

Requirements:

- macOS with Xcode's Swift toolchain. An open-source toolchain earlier on
  `PATH` cannot build the app.
- Network access for the MapKit basemaps. The videos need it; the summary
  cards do not.
- Python 3 for realpath resolution before writing anything.

The exit status is 0 on success, 1 when the curated set is over the size
budget (see below), 2 for any other failure, and 64 for a usage error.

The manually triggered **Demo Assets** workflow
([`.github/workflows/demo-assets.yml`](../.github/workflows/demo-assets.yml))
runs the script on a hosted macOS runner. It uploads everything as the
`runplay-demo-assets` artifact, kept for 30 days. To start it, go to
**Actions → Demo Assets → Run workflow** and pick a branch. It never commits.
Neither the script nor the workflow is part of CI, and nothing in CI compares
the committed media with the renderer.

## Reproducibility

Every input that shapes a pixel is fixed:

- **Data:** the bundled synthetic runs, imported by the app's importer.
- **Randomness:** the pipeline's only random values are identifiers (the
  `UUID`s of route points, segments, and card rows), and none of them reaches a
  pixel. Swift's per-process `Hasher` seed is the one seed in play, so the
  script sets `SWIFT_DETERMINISTIC_HASHING=1`. If renders ever stop repeating,
  look first for iteration over a `Set` or `Dictionary` keyed by those
  identifiers, which no fixed seed makes repeatable.
- **Locale, language, time zone:** the card's date line follows the current
  locale and time zone, the replay HUD follows the time zone, and MapKit labels
  follow the preferred language. The script passes `-AppleLocale en_US`,
  `-AppleLanguages '(en-US)'`, and `TZ=UTC`.
- **Appearance:** Light and Dark are each rendered on purpose. The system
  appearance is never read, so a Mac in Dark Mode renders the same bytes.
- **Sizes:** the card is 1200×1600 at scale 1 and the videos are 1920×1080 at
  30 fps, both from the export policies. The GIF is 720 px wide at 10 fps. No
  window or display is involved, so no window size or display scale can leak
  in.

The app checks every pin before it renders. It refuses to start if one is
missing or if a user date-format override, such as a forced 24-hour clock, is
active. A direct launch therefore cannot quietly produce different pixels.

How far the results reproduce:

- **Summary PNGs:** byte-identical across runs on one macOS build. Text
  rasterization can change between macOS builds, so cards rendered on
  different builds can differ without any UI change.
- **MP4s:** the frame content is fixed except for the basemap. The basemap is
  Apple Maps imagery fetched at render time, so it changes as Apple updates its
  map data. The bytes also vary from run to run: the hardware H.264 encoder
  does not turn identical frames into identical output.
- **GIFs and posters:** derived from each actual encoded Route Replay, so
  they carry over the MP4's variation. ImageIO is part of macOS.

## The GIF Step

The debug-only headless app samples each Route Replay MP4 at 2× playback,
encodes an infinite loop with ImageIO at 10 frames/s, and writes the first
frame as a static PNG. The README uses the corresponding Light or Dark poster
when reduced motion is requested.

## Size Budget

Only the curated set is committed to `docs/assets/`:
`demo-summary-{light,dark}.png` (about 120 KB each),
`demo-route-replay-{light,dark}.gif`,
`demo-route-replay-{light,dark}-poster.png`, and `demo-assets-provenance.txt`.

- At most **3 MB per file** and **7 MB in total**. Generation checks the
  curated set it produced and fails when it is over either limit.
- The MP4s are about 12 MB each and are never committed. They exist only in
  the workflow artifact.
- Every committed byte stays in clone history, so refresh only when the README
  media would visibly change.

## Refreshing docs/assets

The script never writes to `docs/assets/`, and no workflow commits. A refresh
is an ordinary reviewed change, normally in the same PR as the UI change that
caused it:

1. Run `./scripts/generate-demo-assets.sh`, or run **Demo Assets** on the PR
   branch and download `runplay-demo-assets`. The workflow's runner image
   decides the text rasterization, so prefer it when the cards matter.
2. Copy only the curated files into `docs/assets/`:
   `demo-summary-light.png`, `demo-summary-dark.png`,
   `demo-route-replay-light.gif`, `demo-route-replay-dark.gif`, their matching
   `-poster.png` files, and
   `demo-assets-provenance.txt`. When you copy only the cards, keep the
   provenance file's `macos:` line in step with them.
3. Open each file and look at it.
4. Stage the files by name (`git add docs/assets/<file>`), commit, and push.

The cards are binary and cannot be merged. Two open PRs that both change the
summary card conflict on them, so land one and regenerate the other.
Adding or renaming a summary-card appearance changes the committed set, so
commit the new files in the same change.

## Implementation

- `scripts/generate-demo-assets.sh`: build, safe output directory, pinned launch,
  provenance, checksums, and the size budget.
- `RunPlayStudio/Sources/RunPlayStudioEntryPoint.swift`: the process entry
  point. In debug builds, it sends a `--demo-assets` launch to the headless
  mode.
- `RunPlayStudio/Sources/DemoAssets/`: the specification, environment pins,
  bundled-data loading and rendering (`DemoAssetGenerator.swift`), and
  argument parsing and exit codes (`DemoAssetCommand.swift`). The tool has no
  tests: its guarantees are runtime checks that fail the render with a
  message.
- `.github/workflows/demo-assets.yml`: the manual workflow.
