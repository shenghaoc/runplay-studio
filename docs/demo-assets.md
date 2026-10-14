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

## What Is Generated

| File | Export | Fixed settings |
|------|--------|----------------|
| `demo-summary-{light,dark}.png` | PNG summary card | Metrics-only layout, exactly 1200×1600 at scale 1 |
| `demo-route-replay-{light,dark}.mp4` | Route Replay | 1920×1080, 30 fps, 15 s preset (450 frames), heart-rate route colouring |
| `demo-comparison-replay-{light,dark}.mp4` | Comparison Replay | Same media contract, Route-Aware alignment |
| `demo-route-replay-{light,dark}.gif` | Derived from the Route Replay MP4 | 720×405, 10 fps, 7.5 s loop at 2× playback |
| `demo-assets-provenance.txt` | — | The macOS, Xcode, and ffmpeg versions that made the files |
| `SHA256SUMS` | Checksums of the files above | — |

The summary card uses the metrics-only layout because the map-inclusive one
embeds live Apple Maps imagery, which no pixel check could hold still. The
replays need a basemap and always fetch one. That basemap is Apple Maps
imagery, so the README credits Apple Maps next to the GIF. The generator does
not fall back silently: it fails if heart-rate colouring or Route-Aware
alignment is unavailable, and `DemoAssetGeneratorTests` checks both conditions
for the bundled runs.

The settings live in `DemoAssetCatalog`
(`RunPlayStudio/Sources/DemoAssets/DemoAssetGenerator.swift`).

## Running It

```bash
./scripts/generate-demo-assets.sh
```

The output goes to `.build/demo-assets/`, which git ignores. `--output-dir`
picks another directory, resolved from the current directory. Inside the
repository only `.build/` is accepted, so generated media cannot land where
git would see them. The script also refuses a non-empty directory it did not
create. `--skip-build` reuses the existing debug build, and `--skip-gif` skips
the ffmpeg step.

Requirements:

- macOS with Xcode's Swift toolchain. An open-source toolchain earlier on
  `PATH` cannot build the app.
- Network access for the MapKit basemaps. The videos need it; the summary
  cards do not.
- `ffmpeg` on `PATH` for the GIF step. Without it, the script stops before it
  builds anything and says so.

The exit status is 0 on success, 1 when `--check` finds drift or a budget
breach, 2 for any other failure, and 64 for a usage error.

The manually triggered **Demo Assets** workflow
([`.github/workflows/demo-assets.yml`](../.github/workflows/demo-assets.yml))
runs the script on the same `xcode-27` runner image as CI. It installs
Homebrew's current ffmpeg bottle, whose version lands in
`demo-assets-provenance.txt`, and uploads everything as the
`runplay-demo-assets` artifact, kept for 30 days. To start it, go to
**Actions → Demo Assets → Run workflow** and pick a branch. It never commits.

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

- **Summary PNGs:** byte-identical across runs on one macOS build. CI checks
  them (see below).
- **MP4s:** the frame content is fixed except for the basemap. The basemap is
  Apple Maps imagery fetched at render time, so it changes as Apple updates its
  map data. The bytes also vary from run to run: the hardware H.264 encoder
  does not turn identical frames into identical output.
- **GIFs:** byte-identical for a given MP4 and ffmpeg build, so they carry
  over the MP4's variation. Their size moves by a few percent between runs.

## The GIF Step

For each `demo-route-replay-*.mp4`, the script runs:

```bash
ffmpeg -hide_banner -loglevel error -nostdin -y -i demo-route-replay-light.mp4 \
  -filter_complex 'setpts=0.5*PTS,fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle' \
  -loop 0 -map_metadata -1 demo-route-replay-light.gif
```

- `setpts=0.5*PTS` plays the 15 s replay at 2×, so the whole route loops in
  7.5 s.
- `fps=10` and `scale=720:-1` set the frame rate and size, with Lanczos
  scaling.
- `palettegen=stats_mode=full` builds one 256-colour palette from every frame.
- `dither=none` skips dithering, which the flat map colours do not need and
  which would add frame-to-frame noise and bytes.
- `diff_mode=rectangle` stores only each frame's changed rectangle.
- `-loop 0` loops forever, and `-map_metadata -1` copies no source metadata.

## The CI Drift Check

```bash
./scripts/generate-demo-assets.sh --check
```

CI's macOS full-tests leg runs this check right after `swift test`, reusing
that build; it is the `demo-assets` input of
`.github/workflows/macos-verify.yml`. The release lane does not run it: the
gate guards documentation, so a runner-image roll that changes text
rasterization must not block a release.

The check renders the summary cards and compares each one with its copy in
`docs/assets/`:

- Both images are drawn into the same 8-bit sRGB RGBA layout. A pixel
  differs when any channel differs by more than 16/255. The check fails when
  more than 8 pixels differ, when the sizes differ, or when the rendered
  cards and the committed cards are not the same set.
- Calibration: two renders differ by 0 pixels. One changed digit in a 14-pt
  split time, the card's smallest data text, moves 36 to 60 pixels past the
  channel bound, depending on the digits; one in an 18-pt metric value about
  110. `DemoAssetGeneratorTests` checks both cases.
- The check also enforces the size budget below.
- It prints the macOS build recorded in `docs/assets/demo-assets-provenance.txt`
  next to its own. When they differ and the check fails, it says so, because a
  macOS update can change text rasterization without any UI change.
- On failure, CI uploads the `demo-asset-drift` artifact. It holds the
  rendered cards, a `*.diff.png` for each changed card (the reference faded,
  the changed pixels in magenta), and the runner's provenance file. The run
  page also shows an error annotation.

The videos and GIFs are not compared, because their basemap is Apple's live
map data.

The tolerance lives in `DemoAssetPixelTolerance.summaryCard`
(`RunPlayStudio/Sources/DemoAssets/DemoAssetImageComparison.swift`).

The committed cards should come from the CI runner image. A Mac on a different
macOS build can rasterize text differently. If `--check` passes on your Mac but
fails in CI (or the other way round), the runner's rendering wins.

## Size Budget

Only the curated set is committed to `docs/assets/`:
`demo-summary-{light,dark}.png` (about 120 KB each),
`demo-route-replay-{light,dark}.gif` (2.5–2.7 MB each), and
`demo-assets-provenance.txt`.

- At most **3 MB per file** and **7 MB in total**. `--check` enforces both.
- The MP4s are about 12 MB each and are never committed. They exist only in
  the workflow artifact.
- Every committed byte stays in clone history, so refresh only when the README
  media would visibly change.

## Refreshing docs/assets

The script never writes to `docs/assets/`, and no workflow commits. A refresh
is an ordinary reviewed change, normally in the same PR as the UI change that
caused it:

1. Run **Demo Assets** on the PR branch and download `runplay-demo-assets`.
   If only the summary cards changed, the `demo-asset-drift` artifact from the
   failing CI run already holds runner-rendered cards and provenance.
2. Copy only the curated files into `docs/assets/`:
   `demo-summary-light.png`, `demo-summary-dark.png`,
   `demo-route-replay-light.gif`, `demo-route-replay-dark.gif`, and
   `demo-assets-provenance.txt`. When you copy only the cards, keep the
   provenance file's `macos:` line in step with them.
3. Open each file and look at it.
4. Stage the files by name (`git add docs/assets/<file>`), commit, and push.
   CI's drift check confirms both the cards and the budget on the runner
   image.

The cards are binary and cannot be merged. Two open PRs that both change the
summary card conflict on them, so land one and regenerate the other.
Adding or renaming a summary-card appearance changes the set the check
expects, so commit the new reference in the same change.

## Implementation

- `scripts/generate-demo-assets.sh`: build, pinned launch, GIF step,
  provenance, checksums, `--check`, and the budget.
- `RunPlayStudio/Sources/RunPlayStudioEntryPoint.swift`: the process entry
  point. In debug builds, it sends a `--demo-assets` launch to the headless
  mode.
- `RunPlayStudio/Sources/DemoAssets/`: the specification, environment pins,
  bundled-data loading and rendering (`DemoAssetGenerator.swift`), the pixel
  comparison (`DemoAssetImageComparison.swift`), and argument parsing and exit
  codes (`DemoAssetCommand.swift`).
- `RunPlayStudio/Tests/RunPlayStudioTests/DemoAsset*Tests.swift`: tests for
  the specification, pins, comparison, parser, and tolerance.
- `.github/workflows/demo-assets.yml` and the **Check README demo assets**
  step in `.github/workflows/macos-verify.yml`.
