# RunPlay Studio — Demo Script

A 3–5 minute walkthrough showing RunPlay Studio's core capabilities using
bundled synthetic demo data.

## Prerequisites

- macOS 26.0+
- Xcode 26.4+ or Swift 6.3+ toolchain
- Clone the repository and build:

```bash
git clone https://github.com/shenghaoc/runplay-studio.git
cd runplay-studio
open Package.swift
```

Select the **RunPlayStudio** scheme, choose **My Mac**, and press **⌘R**.

The app launches with two bundled synthetic demo runs pre-loaded.

---

## Demo Flow

### 1. Launch and Overview (~30 seconds)

- The app opens with the **Overview** tab showing both bundled runs.
- Point out the sidebar listing the two demo runs (a 5K park run and a
  comparison park run).
- Click one run to select it as the primary.
- Point out **Elapsed**, **Active**, and **Pace** in the summary. Elapsed
  includes recording gaps; Active and Pace exclude them.

> **Key point:** No account, no cloud, no sign-up. Everything runs locally.

### 2. Apple Maps 2D/3D Route Replay (~60 seconds)

- Switch to the **Map** tab.
- Use the map's native pitch toggle to switch the same route between 2D and 3D.
- Point out realistic terrain/buildings, the blue route, and start/finish markers.
- Press **Play** to watch the yellow position marker travel along the route.
- Pan, rotate, and zoom using standard Apple Maps interactions.
- Press **Fit Route** to restore the route framing without leaving the map.

> **Key point:** 2D and 3D are two presentations of one real map, not separate
> renderers or a textured 3D plane.

### 3. Charts and Segment Highlights (~45 seconds)

- Switch to the **Charts** tab.
- Show pace, elevation, and heart-rate charts over distance.
- **Click or drag on a chart** to seek the replay to that position — the map
  marker, map marker, and metrics panel all update.
- Switch to the **Segments** tab.
- Show auto-detected segments: fastest 400m, fastest 1km, slowest 1km,
  biggest climb, biggest descent.
- Click a segment to seek the replay to it.

> **Key point:** Chart click-to-seek and segment detection make it easy to
> find the interesting parts of a run.

### 4. Route Comparison (~60 seconds)

- Switch to the **Compare** tab.
- The primary run is already selected. Pick the other bundled run as the
  comparison.
- Show the **summary deltas**: distance, Active Time, Elapsed Time, active pace (min/km), elevation
  gain, heart rate — each with faster/slower or longer/shorter labels.
- Show the **split active-pace comparison table** with min/km values, delta, and
  winner columns.
- Show the **active pace over distance chart** with both runs plotted. Point out
  the legend uses actual workout names and the y-axis shows min/km.
- If warnings appear (different distances, missing data), explain what they
  mean.

> **Key point:** Comparison is distance-aligned and shows exactly where one
> run was faster or slower.

### 5. Comparison Map Toggle and Distance Slider (~45 seconds)

- Use the comparison map's native pitch toggle to switch the same overlay from
  2D to 3D.
- Primary stays blue and comparison stays orange in both modes.
- Use the **distance slider** at the bottom to scrub along the common route
  distance.
- As you drag, both "P" and "C" markers move along their routes, and the
  readout distinguishes elapsed-time, active-time, and active-pace deltas at
  that distance.
- Try the start, midpoint, and end positions.

> **Key point:** The comparison distance slider lets you see exactly where
> both runners were at the same point in the race.

### 6. Export (~20 seconds)

- Open the **Export** menu.
- Show the available export formats: JSON summary, splits CSV, segments CSV,
  combined CSV, and PNG summary card.
- Point out that clock and pace labels are explicit: elapsed, active, paused,
  active pace, and elapsed pace.
- Explain that all exports are local files — nothing is uploaded.

> **Key point:** Export your data in standard formats for analysis elsewhere.

### 7. Privacy Recap (~15 seconds)

- Summarize: local-only, no cloud, no analytics, no telemetry, no account,
  no AI API.
- All data stays on your Mac. Delete the app and everything is gone.

---

## Tips

- Use the bundled demo runs for all public demos — no private workout data
  needed.
- If you import your own runs, keep them in `local-workouts/` or
  `private-workouts/` (both are gitignored).
- The app supports JSON, GPX, TCX, and common FIT running-activity imports.
- Comparison works best when both runs cover similar routes and distances.
- Moving-time estimation is not implemented; Active means recorded time inside
  continuous route segments.
- For very different route lengths, warnings explain that only the common
  distance is compared.

## What RunPlay Studio Is NOT

- Not a live run tracker
- Not a Strava clone
- Not a social network
- Not a web app
- Not an AI product

It is a focused, local-native macOS tool for visualizing and comparing
completed running workouts in 3D.
