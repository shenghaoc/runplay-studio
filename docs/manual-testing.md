# RunPlay Studio Manual Testing

Manual checks supplement the SwiftPM test suite. Keep results concrete and avoid
committing local workout files or generated exports.

Use the warning-clean SwiftPM and Xcode commands in `AGENTS.md` and live CI for
automated status. Dated manual GUI evidence is recorded with the relevant
checklist below; unchecked items have not been manually verified.

The durable accessibility matrix lives in
[accessibility-audit.md](accessibility-audit.md).

## Running a check against a throwaway library

Set `RUNPLAY_LIBRARY_ROOT` to point the app at a scratch library instead of
`~/Library/Application Support/RunPlayStudio`:

```bash
RUNPLAY_LIBRARY_ROOT=/tmp/runplay-check ./dist/RunPlayStudio.app/Contents/MacOS/RunPlayStudio
```

`HOME` does not do this: Application Support resolves through the OS, not the
environment, so a launch without the override opens the real library — and on
an analysis-version bump migrates and rewrites every workout in it. Use the
override for any check that imports, deletes, or migrates.

## Keyboard and VoiceOver Checklist

Use only synthetic or approved repository fixtures. Enable Full Keyboard Access
for the keyboard-only pass. Do not claim a spoken VoiceOver pass from
Accessibility Inspector alone.

- [ ] Launch the packaged `.app`; open and reopen the main window.
- [ ] Sidebar: All Runs, Heatmap, smart collection, favourite, recent.
- [ ] All Runs: ⌘F search, Escape clear (search focused), Return open one row, Delete one persisted row.
- [ ] Filters, sort, bulk tags, create tag, smart collection save/update/delete via keyboard.
- [ ] Workout tabs ⌘1–⌘4; Replay Space, ⌥←/→ seek, [ / ] speed, ⌘⇧← restart.
- [ ] Bare arrows do not break table/list/slider when replay is not focused.
- [ ] Space does not play while editing metadata notes.
- [ ] Charts: Jump to distance; VoiceOver chart summary; seek earlier/later actions.
- [ ] Map: Fit (⌘0), View → Toggle 2D/3D, Route Color menu, legend summary.
- [ ] Comparison: textual P/C identity; Distance / Route-Aware alignment picker; distance or matched-route slider; End Comparison.
- [ ] Heatmap: filters, Fit Heatmap, summary statistics.
- [ ] Import file, multi-session FIT review, and Strava archive; cancel sheets with Escape.
- [ ] Watch Folders: File menu item opens the settings pane; add/remove/pause, Import Existing Files Now, Recent Imports popover, and review banner are all reachable and operable by keyboard; Escape closes the Recent Imports popover, and the banner's focused Dismiss button clears it.
- [ ] PNG export configuration, preview, save/cancel.
- [ ] Video export configuration, poster preview, 15/30/60 s encode, cancel cleanup.
- [ ] Help → Keyboard Shortcuts matches live menu chords.
- [ ] Reduce Motion: map fit jumps without animation; replay still works.
- [ ] Differentiate Without Colour: comparison shows P/C markers.
- [ ] Increased Contrast / Reduce Transparency: panels and controls remain legible.
- [ ] VoiceOver: no announcement spam during replay, archive, or FIT session progress.

## Native Route Metric Coloring Checklist

Use only synthetic or approved repository fixtures. Do not claim scenarios that
were not performed. Metric modes are **relative to the selected workout** —
not personalized HR zones or grade-adjusted pace.

- [x] Launch a workout with pace, HR, and elevation data.
- [x] Confirm Solid is the default (or the persisted `@AppStorage` preference).
- [x] Switch to Pace; faster/slower sections are visibly distinct.
- [x] Confirm the legend shows relative pace within this workout with numeric ends.
- [x] Switch to Heart Rate; higher/lower areas appear; missing HR is neutral no-data.
- [x] Switch to Elevation; coloring follows corrected elevation, not raw spikes.
- [x] Toggle 2D and 3D in every mode; route remains consistent.
- [x] Replay the workout; the yellow marker stays responsive and is not recolored.
- [x] Switch color mode during playback; map does not blank; replay continues.
- [x] Open a workout without HR; Heart Rate is disabled or falls back with help.
- [x] Open a multi-segment workout; no line bridges a recording gap.
- [x] Open comparison; primary stays blue, comparison stays orange (no metric leak).
- [x] Open Personal Heatmap; density palette and controls are unchanged.
- [x] Inspect keyboard focus and VoiceOver labels on Route Color and legend.
- [x] Toggle light/dark appearance; metric colors remain legible over the basemap.
- [x] Quit/relaunch; route-color preference is restored.

Native route-coloring smoke record (2026-07-22): the packaged SwiftPM app was
launched with an isolated `CFFIXED_USER_HOME` and the bundled synthetic runs.
Solid, Pace, Heart Rate, and Elevation stayed fitted while switching between 2D
and 3D. Pace, HR, and elevation legends exposed relative numeric bounds. Replay
advanced to 0:16 while the current marker remained present, and switching from
Elevation to Pace did not stop playback or blank the map. Comparison retained
blue/orange identity and Personal Heatmap retained its density UI. A forced-light
test bundle and the normal dark appearance both kept the route and legend
legible. The selected mode survived workout changes and a packaged-app relaunch.
Importing the synthetic `realistic_5k_run.gpx` fixture exposed `Heart Rate —
Unavailable` with a coverage explanation. A temporary synthetic two-segment GPX
then showed 91% HR coverage with a neutral no-data span, no bridge across the
recording gap, and corrected elevation bounds of 12–24 m while the analysis
reported that a raw 900 m spike had been ignored. Accessibility inspection found
the labelled Route Color control and combined numeric legend; arrow-key/Return
operation selected a menu mode without pointer input.

## Personal Heatmap Checklist

Use only synthetic or explicitly private, ignored local workout files. Do not
commit screenshots of real home locations or personal heatmap exports.

- [ ] Launch with several GPS workouts in the library.
- [ ] Open **Personal Heatmap** from the Library sidebar section (or Library → Personal Heatmap / ⌘⇧H).
- [ ] Confirm the map fits rendered heat cells on first appearance.
- [ ] Confirm repeated corridors look stronger than one-off paths.
- [ ] Confirm one dense-sampling workout does not overpower a sparse recording of the same path.
- [ ] Confirm route gaps do not draw a connecting hot corridor.
- [ ] Switch Fine (25 m) / Standard (50 m) / Broad (100 m); effective cell size label updates.
- [ ] Change minimum repeat count (1 / 2 / 3 / 5).
- [ ] Change All Time, Last 30 Days, Last 90 Days, This Year, and a custom range.
- [ ] Confirm an excluding date range shows the filter-empty state with All Time / Reset.
- [ ] Import a workout; library updates and heatmap recomputes when reopened or after filters refresh.
- [ ] Delete a workout while heatmap is visible; counts update and workspace stays on heatmap.
- [ ] Select a workout; normal workout workspace returns.
- [ ] Enter and leave comparison; heatmap and comparison never share the same workspace state.
- [ ] Verify keyboard shortcut and sidebar accessibility selection state.
- [ ] Inspect VoiceOver labels on legend, filters, and Fit Heatmap.
- [ ] Toggle light/dark appearance; heat fills remain legible.
- [ ] Resize the window; pan and zoom the map; use Fit Heatmap.
- [ ] Confirm single-route and comparison maps still render correctly.
- [ ] Relaunch: workout library persists; heatmap is recomputed (not stored as a second route DB).

### 2026-09-15 layout pass

Driven through computer use against the seeded two-run demo library, launched
with `RUNPLAY_LIBRARY_ROOT` so the real library was not opened.

The workspace stack had the same window-inflation flaw Trends had: it sized
itself to its content's ideal height, the centred overflow cut off the top, and
the filter bar sat 129 pt above the window top at the app's default 1200x766
window and 35 pt above at full screen. The fix gives the stack the window's
height from a GeometryReader, as in TrendsView.

After the fix, measured through the accessibility tree: at the default
1200x766 window the filter bar (Date range, Resolution, Minimum repeats, Fit
Heatmap) sits at y=224 with the window top at y=94, and the legend ends 8 pt
above the window bottom; zoomed to full screen (1512x884 on this display) the
filter bar sits at y=163 with the window top at y=33. Every filter control was
exercised: Date range switched to Last 30 Days (the excluding range showed the
filter-empty state; its All Time button restored the heatmap), Resolution
switched Standard → Fine (25 m), Minimum repeats switched 1 → 2 runs, and Fit
Heatmap was clicked; the statistics row and the map recomputed after each
change. Still open here: the remaining date presets and custom range, the
Broad resolution, minimum repeats 3 and 5, import/delete while visible,
VoiceOver labels, and a manual pan/zoom pass.

Four items in the checklist above were un-ticked afterwards, on review: that
pass ran against a two-run library rather than "several" workouts, it did not
open the workspace through Library → Personal Heatmap or ⌘⇧H, it did not
observe the automatic fit on first appearance (only the Fit Heatmap button),
and in the filter-empty state it pressed All Time but never Reset Filters.

### Pending pass: shared workspace container

The GeometryReader that pins each workspace to the window has since moved out
of TrendsView and PersonalHeatmapView into one `fillsWorkspace()` modifier
applied to the detail column in `ContentView`, and the heatmap's custom date
range has moved to its own row beneath the filter bar. The change is covered by
`swift test` only as far as the view models go; **the layout itself has not
been re-verified in the running app**. Needs a pass over:

- [ ] Every workspace still fills the window and none is clipped at the top:
      Personal Heatmap, Trends, All Runs, a workout, and a comparison.
- [ ] The workout workspace still shows its Compare / Export toolbar items —
      they are attached inside the detail column that is now wrapped.
- [ ] Personal Heatmap with Date range → Custom at the 720x500 minimum window
      size: the From/To pickers sit on their own row and Fit Heatmap stays on
      screen and clickable.
- [ ] The custom range's two pickers cannot be crossed over each other.

### Filter bar width pass 2026-09-23 (#160; release configuration, synthetic 317-run library)

The primary filter row now picks the widest arrangement that fits instead of
compressing one `HStack`. The order is: one row, then labelled pickers over a
route + Fit row, then the same two rows without the static labels, and last,
date + resolution over repeats + route + an icon-only Fit, where only the route
title may truncate. Driven with System Events, `screencapture`, and an AX
attribute dump against a release bundle, on a copy of the generator's 317-run
library (286 routes).

- 720×552, sidebar visible, light and dark: the last arrangement was used. No
  label wrapped, and every pop-up showed its full value. With "1.0 km Loop
  (NE·747)" selected the route title showed in full beside the icon-only
  Fit button.
- 720×552 with Date range → Custom (dark): the From/To row sat beneath the two
  filter rows and the Fit button stayed on screen. The button was not clicked.
- 720×552, sidebar hidden: labels dropped, and the route title and "Fit
  Heatmap" were both shown in full.
- A user name of 49 characters, set in the scratch library's manifest, was the
  one case that truncated: one line with a tail ellipsis. The AX value kept the
  full name. A macOS menu label ignores `truncationMode(.middle)`.
- 1200×800, light and dark: labelled pickers on the first row, route and Fit
  Heatmap on the second. At their natural widths the three labelled pickers
  need about 723 pt. A single row comes back only in a window around 1330 pt
  wide. Before #160 the row fit at 1200 only because the `maxWidth` caps
  squeezed the pickers, which is also what made the labels wrap.
- AX descriptions in the unlabelled arrangements read "Date range",
  "Resolution", "Minimum runs per cell", and the icon-only button reads
  "Fit Heatmap". An earlier build used `labelsHidden()`, and those descriptions
  came out doubled ("Date range, Date range"). The label is now omitted instead.

Not covered: VoiceOver speech (only AX attributes were read), and a clicked Fit
button at the minimum size.

### Route filter Item Chooser pass 2026-09-23 (#161; release configuration, bundled two-run demo library)

The Item Chooser (VO+I) listed the route filter as "Any Route Route filter
Downward point at the top-left corner of to point at the bottom-right corner
of curvepath". An AX attribute dump of the release bundle showed where each
part comes from: AXValue "Any Route" from `accessibilityValue`, AXTitle
"Route filter" from `accessibilityLabel`, and AXDescription, which held the
generated symbol name. The Item Chooser reads value, title, description, and
role. Focus reads value, title, and role, which is why focus was clean.

Several label variants were built in one release bundle and read with the AX
dump and the Item Chooser:

- `Image(systemName:)` with `.accessibilityHidden(true)`, with
  `.accessibilityLabel(Text(""))` or with a real label, or the `Label` wrapped in
  `.accessibilityElement(children: .ignore)`: the generated name stayed.
- An `NSImage(systemSymbolName:accessibilityDescription:)` symbol with an empty
  description: the generated name stayed, because AppKit treats an empty
  description as none.
- The same `NSImage` symbol described as "Route filter": the generated name was
  gone, but the chooser said "Route filter" twice.
- A menu with no `accessibilityLabel`: there was no description at all, but
  "Route filter" was not spoken either.
- The same `NSImage` symbol with a one-space description: the chooser read
  "PHvalue ProbeH   menu button", with nothing between the title and the role.
  The fix uses this variant, as `DecorativeMenuSymbol`.

On the fixed build:

- AXDescription is `" "`.
- The Item Chooser, filtered to "route filter", read "Any Route Route
  filter   menu button".
- VoiceOver focus still read "Any Route, Route filter, menu button", followed
  by the help text.
- The icon still rendered beside the title.

An AX scan of every menu and pop-up button on Personal Heatmap, All Runs,
Routes, Trends, and Records found no other generated symbol description. Only
a `Menu` whose `accessibilityLabel` differs from its visible title leaks one.

Follow-up on the same build, on a fresh library holding the Routes fixture
generator's runs with `filler_count` lowered to 10 (27 runs):

- "2.0 km Loop (NE·74e)" was selected through the menu. The Item Chooser read
  "2.0 km Loop (NE·74e) Route filter   menu button", and focus read "2.0 km
  Loop (NE·74e), Route filter, menu button".
- In dark appearance the icon rendered beside the title and AXDescription
  stayed `" "`. The system appearance was restored to light afterwards.
- Found, and present before this change as well: the button sometimes reports
  the visible route name as its AXTitle instead of "Route filter". This
  happened after Open Personal Heatmap from the import report and after an
  appearance switch. Navigating away and back restores it. Filed as #196.

### Filter picker Item Chooser pass 2026-09-23 (#195; release configuration, bundled two-run demo library)

In the labelled filter arrangements the Item Chooser (VO+I) listed the date
picker as "All Time Date range Date range pop up button". An AX attribute dump
showed two names on each labelled pop-up: an AXTitleUIElement linked to the
visible label, and an AXDescription from the explicit `accessibilityLabel`. The
Item Chooser reads both. Resolution was doubled the same way. The repeats
picker read "Minimum repeats Minimum runs per cell". The unlabelled
arrangements have only the AXDescription and were already clean.

The explicit label now applies only when the visible label is omitted. The
repeats picker is named "Minimum repeats" in every arrangement. On the fixed
release bundle, VoiceOver was driven through System Events, and speech was read
from the caption panel:

- 1200×800, labelled, two rows: there is no AXDescription. The Item Chooser read
  "All Time Date range pop up button", "Standard (50 m cells) Resolution pop up
  button", and "At least 1 run Minimum repeats pop up button". Choosing each
  entry moved the VoiceOver cursor there, and it announced "All Time, Date
  range, pop up button", "Standard (50 m cells), Resolution, pop up button",
  and "At least 1 run, Minimum repeats, pop up button".
- 1480×800, labelled, one row: the AX attributes matched 1200. Speech was not
  captured at this width.
- 1000×800, unlabelled: AXDescription "Date range", "Resolution", and "Minimum
  repeats", with no title element. The Item Chooser read the same three strings
  as at 1200. Focus read them without the comma after the value ("All Time
  Date range, pop up button").
- 720×800: the AX attributes matched 1000.

Found, and present before this change: Trends and Records pickers also have
two names. On Trends the Item Chooser read "Month Period Trends period pop up
button". The AX dump showed the same shape for Trends Range, Scope and Period
detail, and for Records Scope. Filed as #204. The heatmap legend read "1 run ·
1 runs · 2 runs", filed as #205.

Not covered: dark appearance (no drawing changed), and speech at 720 pt.

## Trends Workspace Checklist

Use only synthetic or explicitly private, ignored local workout files.

- [x] Launch with several dated workouts spanning months (include at least one without heart rate and one without elevation data).
- [x] Open **Trends** from the Library sidebar section (or Library → Trends / ⌘⇧R).
- [x] Confirm four charts appear: Distance, Active Pace, Heart Rate, Ascent; totals use active time.
- [x] Switch Period Week / Month / Year; buckets relabel correctly (weeks start Monday; 29 Dec can belong to week 1 of the next year).
- [x] Switch Range Last 3 / 6 / 12 Months / All Time; the first bar is a whole period (no partial leading bar) and the trailing in-progress period is annotated.
- [x] Confirm periods with no heart rate or elevation show gaps, not zero points, and that the line charts **break** at a gap rather than drawing through it. Grouping the points is not enough: a `LineMark` without its own `series` is joined to every other `LineMark` in the chart, so this is only visible in the running app.
- [x] Mixed periods disclose contributing runs ("from 4 of 7 runs") in the inspector and the statistics row.
- [x] Switch Scope All Workouts / Current All Runs Filter / a smart collection; aggregation rescopes.
- [x] With All Runs showing a smart collection, open Trends for the first time in the session; scope preselects that collection (once; later manual choices persist).
- [x] Hover a bar/point; the inspector shows the period detail with contributor counts.
- [x] Click a bar/point; All Runs opens filtered to that period with the scope preserved (a smart collection shows Modified).
- [ ] Use the inspector period picker and View Runs button with keyboard and VoiceOver.
- [ ] Import a workout; totals update on return to Trends. Delete while Trends visible; workspace stays on Trends.
- [x] Relaunch with Trends as the last workspace; destination, period, range, and scope restore.
- [x] Training Load panel: with a backfillable library, opening Trends shows the computing banner once; it progresses, finishes, and the daily bars + Fitness/Fatigue/Form lines appear without a manual refresh.
- [x] Training Load honesty rules: a run without heart rate shows a lighter estimated bar that the captions exclude from the model; the "Include estimated loads" toggle redraws the curve and changes the caption; HR coverage percentage is shown for the window.
- [x] Hover the training-load chart; the readout shows the day's load (labelled "estimated, not in model" on HR-less days), fitness, fatigue, and form.
- [x] Hovering a genuine rest day reads "Rest day", not "No heart-rate load" — the two zeroes must not share a phrase.
- [x] Adjust the Fitness/Fatigue time-constant steppers; the curve reshapes without touching stored data.
- [x] Quit mid-backfill, then relaunch straight back into the restored Trends workspace: the pass resumes on its own, without navigating away and back.
- [x] Unknown-load shading: a stretch of runs with no usable heart rate draws a shaded band behind the Fitness/Fatigue/Form lines, the band starts and ends on the right days, and a single unknown day still gets a full day's width. A rest day inside the stretch splits the band in two.
- [x] Zero-contribution days stay visibly distinct from rest days inside the shaded band (floor marker present on the run day, absent on the rest day) at both the default window and the 720x500 minimum.
- [x] The shading's caption and the chart's tooltip both state the bias direction — unknown-load days decay the model as if rested.
- [x] Toggle "Include estimated loads": the shading stays (an invented value does not make a day measured) and the caption switches to the wording that is true in that mode.
- [ ] The shading caption disappears when no unknown-load stretch is in the displayed range. (Needs a scope or range containing no such day; the fixture set below puts one in every range the picker offers.)
- [ ] VoiceOver speaks the chart summary (fitness, fatigue, form, no-HR-day count, coverage) and the bias disclosure in both opt-in modes. **Not verified by ear.** The strings are unit-tested and the chart carries them as its accessibility value, but the chart element is not exposed to an accessibility-tree walk from outside, and switching VoiceOver on is a system-settings change.
- [ ] Verify VoiceOver chart descriptors and ⌘⇧R in Help → Keyboard Shortcuts.

### Prep: synthetic training-load fixture set

The Routes fixtures do not exercise training load: the model needs months of
dated runs, a controlled stretch with no heart rate, and rest days in the right
places. Two properties matter and are easy to get wrong.

1. **Filler runs must stay out of the designed window.** A filler run *with*
   heart rate landing on a day you meant to be unknown makes that day measured
   and splits the band you are trying to observe. Keep fillers before the
   design window. The first attempt at these fixtures scattered 260 fillers
   across the whole timeline and produced a row of meaningless one-day bands.
2. **The backfill banner only appears for workouts with no stored snapshot.**
   Importing with this build stamps every workout on import, so a fresh import
   never shows the banner. Import with a **pre-feature build** first, then point
   the feature build at the same library — that is the real upgrade path, and
   the only way to see the banner, the progress, and the resume.

```bash
python3 - << 'FIXTURES'
import csv, io, math, os, random, zipfile
from datetime import datetime, timedelta, timezone

BASE_LAT, BASE_LON = 37.7749, -122.4194
M_PER_DEG_LAT = 111_320.0
OUT_DIR = os.environ.get("OUT_DIR", "/tmp/runplay-hrload-fixtures")

def to_latlon(e, n, lat=BASE_LAT, lon=BASE_LON):
    return lat + n / M_PER_DEG_LAT, lon + e / (111_320.0 * math.cos(math.radians(lat)))

def loop(side_m, step_m=25.0):
    per, pts, t = side_m * 4, [], 0.0
    while t <= per:
        p = t % per
        if p < side_m: e, n = p, 0.0
        elif p < 2 * side_m: e, n = side_m, p - side_m
        elif p < 3 * side_m: e, n = side_m - (p - 2 * side_m), side_m
        else: e, n = 0.0, side_m - (p - 3 * side_m)
        pts.append((e, n, t))
        if t >= per: break
        t = min(per, t + step_m)
    return pts

def gpx(name, pts, start, pace_s_per_km, hr_profile, lat=BASE_LAT, lon=BASE_LON):
    # hr_profile None -> no <hr> elements at all; else (mean, swing).
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<gpx version="1.1" creator="RunPlayFixtureGenerator" '
           'xmlns="http://www.topografix.com/GPX/1/1">',
           f"  <trk><name>{name}</name><trkseg>"]
    total = pts[-1][2]
    for e, n, travelled in pts:
        la, lo = to_latlon(e, n, lat, lon)
        ts = (start + timedelta(seconds=travelled / 1000.0 * pace_s_per_km)).strftime("%Y-%m-%dT%H:%M:%SZ")
        alt = 15.0 + 3.0 * math.sin(travelled / 400.0)
        if hr_profile is None:
            ext = ""
        else:
            mean, swing = hr_profile
            frac = travelled / total if total else 0.0
            ramp = min(1.0, frac * 5.0)
            bpm = mean - swing + 2 * swing * ramp * (0.85 + 0.15 * math.sin(frac * 6.0))
            ext = ("<extensions><gpxtpx:TrackPointExtension "
                   'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">'
                   f"<gpxtpx:hr>{int(round(bpm))}</gpxtpx:hr>"
                   "</gpxtpx:TrackPointExtension></extensions>")
        out.append(f'    <trkpt lat="{la:.7f}" lon="{lo:.7f}"><ele>{alt:.1f}</ele>'
                   f"<time>{ts}</time>{ext}</trkpt>")
    return "\n".join(out + ["  </trkseg></trk>", "</gpx>"])

acts, nid = [], [7000]
def add(name, pts, start, pace, hr, lat=BASE_LAT, lon=BASE_LON):
    acts.append((nid[0], name, gpx(name, pts, start, pace, hr, lat, lon), start)); nid[0] += 1
def D(y, m, d, h=7): return datetime(y, m, d, h, 0, tzinfo=timezone.utc)

rnd = random.Random(4242)
base_loop, short_loop = loop(1250.0, 3.0), loop(700.0, 3.0)

# Base period: measured HR, ~4 runs/week, Aug 2025 - Jun 2026.
day, i = D(2025, 8, 1), 0
while day < D(2026, 7, 1):
    if day.weekday() in (0, 2, 4, 6):
        pts = [(e + rnd.uniform(-6, 6), n + rnd.uniform(-6, 6), t)
               for e, n, t in (base_loop if i % 3 else short_loop)]
        add(f"Base Run {i+1:03d}", pts, day, rnd.uniform(285, 330), (rnd.uniform(140, 152), 12))
        i += 1
    day += timedelta(days=1)

# The designed unknown-load window. 6-8 Jul is one span; 9 Jul is a REST day
# that must split it; 10-13 Jul is the next; 14 Jul is MEASURED and must split
# again; 15-16 Jul is the last.
for d in (6, 7, 8):        add(f"Strapless {d} Jul", base_loop, D(2026, 7, d), 300, None)
for d in (10, 11, 12, 13): add(f"Strapless {d} Jul", base_loop, D(2026, 7, d), 305, None)
add("Strapped 14 Jul", base_loop, D(2026, 7, 14), 295, (148, 12))
for d in (15, 16):         add(f"Strapless {d} Jul", base_loop, D(2026, 7, d), 310, None)
for d in (20, 23, 26, 29): add(f"Recovery {d} Jul", base_loop, D(2026, 7, d), 300, (146, 12))
for d in (1, 3, 8, 11, 14, 17, 22, 25, 28, 31):
    add(f"August {d:02d}", base_loop, D(2026, 8, d), rnd.uniform(285, 305), (rnd.uniform(142, 150), 12))

# One isolated unknown day (full-day band width) and one with no usable
# estimate at all (floor marker, no bar) - a stationary near-zero-distance run.
add("Strapless 05 Aug", base_loop, D(2026, 8, 5), 300, None)
add("Treadmill No Signal 19 Aug",
    [(0.0, 0.0, 0.0), (0.4, 0.0, 0.4), (0.8, 0.0, 0.8)], D(2026, 8, 19), 300, None)
for d in (2, 5, 9, 12, 16, 19):
    add(f"September {d:02d}", base_loop, D(2026, 9, d), rnd.uniform(280, 300), (rnd.uniform(144, 152), 12))

# Fillers: dense enough that a backfill pass can be interrupted, and stopped
# before 20 Jun 2026 so none of them lands in the designed window above.
for k in range(260):
    pts = [(e + rnd.uniform(-8, 8), n + rnd.uniform(-8, 8), t) for e, n, t in loop(900.0, 2.0)]
    dt = D(2025, 8, 1) + timedelta(days=rnd.uniform(0, 322), minutes=rnd.uniform(0, 600))
    add(f"Filler {k+1:03d}", pts, dt, rnd.uniform(270, 340),
        None if k % 17 == 0 else (rnd.uniform(138, 156), 14),
        BASE_LAT + rnd.uniform(-0.4, 0.4), BASE_LON + rnd.uniform(-0.4, 0.4))

os.makedirs(OUT_DIR, exist_ok=True)
buf = io.StringIO(); w = csv.writer(buf)
w.writerow(["Activity ID", "Activity Name", "Activity Type", "Activity Date", "Filename"])
for aid, name, _, dt in acts:
    w.writerow([aid, name, "Run", dt.strftime("%Y-%m-%dT%H:%M:%SZ"), f"activities/{aid}.gpx"])
zp = os.path.join(OUT_DIR, "hrload_fixtures.zip")
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("export/activities.csv", buf.getvalue())
    for aid, _, g, _ in acts:
        zf.writestr(f"export/activities/{aid}.gpx", g)
print(f"Wrote {zp}: {len(acts)} activities")
FIXTURES

LIB=/tmp/runplay-hrload-check
rm -rf "$LIB" && mkdir -p "$LIB"

# 1. Pre-feature build, from any commit before this stack, to produce a library
#    with no stored training load.
git worktree add --detach /tmp/runplay-prefeature <commit-before-this-stack>
(cd /tmp/runplay-prefeature && ./scripts/assemble-app-bundle.sh \
   --output /tmp/dev-prefeature/RunPlayStudio.app \
   --bundle-identifier dev.local.runplay.hrload)
open --env RUNPLAY_LIBRARY_ROOT="$LIB" -a /tmp/dev-prefeature/RunPlayStudio.app
# File -> Import Strava Archive..., pick the ZIP, Import 483 Runs, Done, quit.
cp -R "$LIB" "$LIB-pristine"   # so the backfill can be re-run from scratch

# 2. Feature build, same library root.
./scripts/assemble-app-bundle.sh --output /tmp/dev-feature/RunPlayStudio.app \
  --bundle-identifier dev.local.runplay.hrload
open --env RUNPLAY_LIBRARY_ROOT="$LIB" -a /tmp/dev-feature/RunPlayStudio.app
```

483 activities, ~790k route points, ~216 MB archive. Backfill progress is
observable from outside the app without guessing at the UI:

```bash
grep -rl trainingLoad "$LIB/workouts" | wc -l   # of 483
```

Set **Range -> Last 3 Months** before reading the chart: at Last 12 Months a
day is under two points wide and band boundaries cannot be judged.

### 2026-09-20 pass: training load

Driven through computer use against the synthetic library above (483 runs,
never dogfood data), release-configuration bundle, throwaway library root.

**The backfill.** Opening Trends on the pre-feature library showed
`Computing training load for earlier runs - 0 of 483` with a progress bar, and
it finished without a manual refresh. ⌘Q during the pass left 116 of 483
snapshots on disk. This found a defect: relaunching restored straight into
Trends and the pass did **not** resume — it sat at 116 with no banner, and the
chart modelled only those 116 while drawing every remaining run day as
unknown-load. Navigating to All Runs and back completed it (116 -> 483), a
workaround nobody would guess. `startTrainingLoadBackfillIfNeeded()` was called
only from `showTrends()`, the navigation path, never from session restore.
Fixed, with a regression test that restores via `applySessionSnapshot`, and
re-verified in the running app: quit at 116, relaunch resumed to 483.

**The shading.** The designed July window rendered exactly as laid out: a
three-day band, a gap at the 9 Jul rest day, a four-day band, a gap at the
14 Jul measured run, then a two-day band. The isolated 5 Aug unknown day drew a
full day's width. 19 Aug — a run with no usable estimate — drew the floor marker
with no bar inside its own one-day band, and stayed distinguishable from the
plain gaps of neighbouring rest days at the 720x500 minimum as well as at full
size. Across the shaded stretch fitness fell and form rose, which is the bias
the caption describes.

**The hover readout.** Three states read distinctly: `Load 31 TRIMP, estimated,
not in model, fitness 38, fatigue 6, form +32 · 11 Jul 2026`; `No heart-rate
load, modelled as rest, fitness 23, fatigue 13, form +10 · 19 Aug 2026`; and
`Rest day, fitness 39, fatigue 8, form +32 · 9 Jul 2026`. The last is a second
defect this pass found and fixed: `dayPhrase` took a `hasHRData` flag, so a
genuine rest day and a strapless run produced the identical phrase — erasing
the exact distinction the shading exists to make.

**The opt-in.** Toggling *Include estimated loads* moved the curve live
(9 Jul: fitness 39 -> 42, fatigue 8 -> 17, form +32 -> +24) and the shading
stayed, correctly: an invented value does not make a day measured. That exposed
a third problem, in the amendment's own copy — the caption asserted "the model
has no load for them" in both modes, which is false once estimates are in. The
wording now splits by mode; both were read back in the running app.

**The steppers.** Fitness 42 -> 45 days reshaped the curve (9 Jul form +24 ->
+25) and the panel header followed (`TRIMP by day · Fitness 45 d · Fatigue 7`).
Stored data untouched.

Still open here: the caption's disappearance when no unknown stretch is in
range, VoiceOver by ear, and the coefficient-set picker's contents — a
background-mode click cannot open a pop-up menu.


### Athlete Profile Settings Checklist (⌘,)

- [x] ⌘, opens Settings; the Athlete section shows blank-optional fields and the not-medical-guidance footer.
- [x] Enter a birth year; the Tanaka estimate caption appears and the derived zone bounds follow it.
- [ ] Change the birth year again; the estimate caption updates. (Only one year was entered in the pass.)
- [x] Enter a measured maximum; the estimate caption disappears (measured wins) and the derived bounds re-derive from the measured value.
- [x] Leave the zone fields blank: the effective-bounds preview shows the derived 60/70/80/90% bounds.
- [ ] Enter five ascending custom zone bounds and the preview follows; malformed input keeps the saved zones.
- [x] The coefficient section shows the magnitude-vs-shape explanation.
- [ ] The coefficient picker lists both cohort sets and switching does not gate anything. (A background-mode click cannot open a pop-up menu; needs a full-screen pass.)
- [x] Update Profile: the saved profile round-trips — set resting HR, quit, relaunch, reopen Settings and the value is still there.
- [x] Closing Settings with unsaved edits discards them; the stored profile and every snapshot are unchanged.
- [x] With a stale or un-backfilled library, the stale count is shown; Recompute Training Loads shows progress, honours Cancel (completed work stays, retry resumes), and finishes with the count at zero.
- [x] Keyboard: Tab moves between the athlete fields.
- [ ] Tab through *every* field and control, and confirm VoiceOver reads labels, footers (including the estimated-exclusion caveat and the not-medical-guidance note) and the recompute progress. **Not verified by ear**; only field-to-field Tab was exercised.

### 2026-09-20 pass: athlete profile settings

Same synthetic 483-run library and release bundle as the Trends pass above.

⌘, opened Settings. Birth year 1990 produced `Estimated maximum from age 36:
183 bpm (Tanaka) — entering a measured value is the upgrade`, which is
208 − 0.7 × 36 to the rounding, and the effective zone bounds moved to
`open / 110 / 128 / 146 / 165 bpm` (60/70/80/90% of 183). Entering a measured
maximum of 192 removed the estimate caption and re-derived the bounds to
`open / 115 / 134 / 154 / 173 bpm`. Those two edits were left unsaved and the
window closed; the stored profile and all 483 snapshots were unchanged
afterwards, confirming the discard path.

The staleness rule was exercised for real. Saving a resting heart rate of 48
turned the footer into `483 runs would be recomputed under the saved profile` —
the whole library, which is correct for a profile-wide change, and the count
matches the library exactly. Recompute showed `Recomputing — 0 of 483 runs`
with a progress bar and a Cancel button; cancelling dropped the pending count
to 133, so 350 completed snapshots were kept rather than rolled back. Pressing
Recompute again finished the remaining work and the stale line disappeared
entirely. On disk all 483 snapshots then carried
`{"restingHeartRateBPM": 48, "trimpCoefficientProfile": "standardMale"}`.

The profile round-trip was verified across a real quit and relaunch: resting
heart rate 48 was still shown when Settings was reopened from a fresh launch.

### 2026-09-15 pass

Driven through computer use against a synthetic 12-run library (15 months,
empty months in Feb/May/Jul 2026, one month with no heart rate, one run with
no altitude, one run outside the 12-month window), launched with
`RUNPLAY_LIBRARY_ROOT`.

Verified: all four panels render; gaps render as gaps at monthly, weekly and
yearly granularity, and a period whose only run carries no altitude is omitted
from Ascent rather than drawn as a zero bar; Period and Range switch correctly
(All Time picked up the twelfth run and moved the disclosures to "from 9 of 12"
and "from 11 of 12"); the Scope menu opens and lists the entire library and the
current All Runs filter; the hover inspector shows a period's detail; clicking
the 2026 bar opened All Runs filtered to exactly the ten runs dated 2026;
session restore returns to Trends with the persisted period and range.

This pass found two bugs. The first was the missing `series` on `LineMark` —
the points were grouped correctly and still drew one continuous line. The
second was the layout: the workspace stack sized itself to the ideal height of
four chart panels, inflated the split view past the window, and the centred
overflow cut off the top — so the header, the statistics row, the Distance
panel and the entire filter bar were unreachable at the app's own default
window size and still unreachable at full screen. Both are fixed.

Scoping was re-run against a library carrying a Trail tag on four of the twelve
runs and a matching smart collection: All Runs scoped to the collection, and
opening Trends preselected it and rescoped to 21.73 km over 4 runs with heart
rate "from 3 of 4 runs" — the four tagged runs exactly. That run found a third
bug: startup restores a synthesized default session even when no session file
exists, and `restoreSessionState` treated that as the user having already
opened Trends, which disarmed the preselect before it could ever fire. It only
passed in tests because they build `AppState` without the session controller.
Fixed, with a regression test on each side of the distinction.

Still open: import or delete while Trends is visible; the ⌘⇧R shortcut itself;
and any spoken VoiceOver output.

**Personal Heatmap had the same layout flaw**, less severely — its filter bar
was clipped by 129 pt at the default window size and 35 pt at full screen. It
was pre-existing and left alone there; it is fixed, and recorded in the
2026-09-15 personal-heatmap pass above. Both workspaces have since been moved
onto one shared `fillsWorkspace()` container; the pending pass noted there
covers Trends too.

## Personal Records Workspace Checklist

Use only synthetic or explicitly private, ignored local workout files. Cover
at least one run shorter than 5 km, one at or beyond marathon length, one
with a mid-run pause, and one without heart rate.

The load-bearing interactions (gap-split highlight geometry, strict-improvement
chip semantics, scoped re-ranking, backfill resume, seek-on-open) are covered
by `RouteMapHighlightTests`, `StandingRecordBadgeTests`, `PersonalRecordsTests`,
and `PersonalRecordsWorkspaceTests`; this pass verifies them visually plus the
layout, timing, and VoiceOver behaviour automation cannot.

### Prep: synthetic fixture set

Generate the four fixtures and run against a throwaway library:

```bash
python3 - << 'PY'
import json, datetime, os
out = "/tmp/runplay-records-fixtures"
os.makedirs(out, exist_ok=True)

def route(total_m, s100, y, mo, d, hr=None, alt=None, pause_at=None, reloc=0.0):
    t0 = datetime.datetime(y, mo, d)
    pts, elapsed, seg = [], 0, 0
    for i in range(total_m // 100 + 1):
        dist = i * 100
        lat = 37.70 + (reloc + (dist - (pause_at or 0)) / 111_000 if seg else dist / 111_000)
        p = {"timestamp": (t0 + datetime.timedelta(seconds=elapsed)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "latitude": round(lat, 6), "longitude": round(-122.42 + dist / 90_000, 6),
             "distanceFromStartMeters": dist, "elapsedSeconds": elapsed, "routeSegmentIndex": seg}
        if hr: p["heartRateBPM"] = hr
        if alt is not None: p["altitudeMeters"] = alt + dist / 1000 * 8
        pts.append(p)
        if pause_at and dist == pause_at and dist < total_m:
            elapsed += 600; seg += 1
        if dist < total_m: elapsed += s100
    return pts

def write(name, pts, y, mo, d):
    json.dump({"metadata": {"name": name, "activityType": "running",
                "startDate": f"{y:04d}-{mo:02d}-{d:02d}T07:30:00Z"},
               "source": "json", "routePoints": pts},
              open(f"{out}/{name}.json", "w"))

write("city_marathon", route(42300, 25, 2026, 9, 13, hr=160, alt=20), 2026, 9, 13)   # 250 s/km
write("first_marathon", route(42300, 26, 2026, 3, 15, hr=150, alt=20), 2026, 3, 15)  # 260 s/km, beaten
write("trail_12k", route(12000, 24, 2026, 8, 20, hr=170, alt=50, pause_at=5000, reloc=0.5), 2026, 8, 20)
write("morning_3k", route(3000, 23, 2026, 9, 1), 2026, 9, 1)                          # no HR, no ascent
PY

BIN=$(swift build --show-bin-path)
./scripts/assemble-app-bundle.sh --output /tmp/dev/RunPlayStudio.app \
  --bundle-identifier dev.local.runplay.records --skip-build --bin-dir "$BIN"
RUNPLAY_LIBRARY_ROOT=/tmp/runplay-records-check open \
  --env RUNPLAY_LIBRARY_ROOT=/tmp/runplay-records-check -a /tmp/dev/RunPlayStudio.app
```

Import the four JSON files (File → Import File…, ⌘I). To rehearse the
backfill, quit, strip the marker from every saved snapshot, and relaunch:

```bash
python3 - << 'PY'
import json, glob
for path in glob.glob("/tmp/runplay-records-check/workouts/*.json"):
    doc = json.load(open(path))
    doc.pop("personalRecords", None)
    json.dump(doc, open(path, "w"))
PY
```

### Checks

- [x] Records opens from the Library sidebar section (or Library → Records /
      ⌘⇧P) with the table populated after the imports above.
- [ ] Against the stripped snapshots, the first Records open runs the inline
      backfill: determinate progress with a current-workout name, counted
      against the whole library from the first frame (the denominator never
      jumps); Cancel keeps completed runs and leaves no error banner behind;
      a later open resumes and finishes without duplicating work. Watch an
      open workout detail while a backfill runs: no per-workout badge
      recompute churn (the revision bumps once per pass).
- [x] Records fits the 720×500 minimum window: header, scope picker, backfill
      banner, and table remain visible and usable.
- [x] Morning 3K shows "—" / Not attempted for 5 km and everything longer —
      never a zero pace; its rows have no HR value (em dash).
- [x] With All Runs showing a search or smart collection, switching Records
      scope re-ranks the tables (equal efforts keep the earlier holder).
- [x] Select a row: the improvement history lists set-or-beat events (newest
      first, at most 10) with dates and values.
- [x] On Trail 12K, open the Fastest 10 km record: the workout opens on
      Overview, replay seeks to the window start, the map shows the heavier
      same-hue overlay **split at the pause** (two segments, no corridor
      across the relocation), and the Charts tab shows the translucent band
      over the same distance range on the pace chart.
- [x] Selecting another workout clears the range highlight; relaunching does
      not restore it.
- [x] City Marathon shows the factual chips under the header; First Marathon
      (beaten pace records, tied distance/ascent) shows only the chips it
      still holds — beaten categories show none, by design.
- [x] The Segments tab lists the original five highlights plus Trail 12K's
      long record windows (1 mile and up), shortest window first; Morning 3K
      shows none beyond the mile. Select a record row and let replay run: the
      selection stays on that row and the list does not reorder.
- [ ] Keyboard and VoiceOver: table selection plus View Workout and history
      rows are reachable without a pointer; the spoken Records summary
      announces standing records and not-attempted categories; ⌘⇧P appears
      in Help → Keyboard Shortcuts.
- [x] Relaunch with Records as the last workspace; destination and scope
      restore.

### 2026-09-18 pass

Driven through Computer Use against the four synthetic fixtures above,
launched from an `assemble-app-bundle.sh` bundle with `RUNPLAY_LIBRARY_ROOT`
pointed at a throwaway library (the developer library was never opened).

Verified: Records opens from the sidebar with the full nine-row table; Morning
3K's not-attempted distances and its HR column render as em dashes with no
zero pace; the scope picker re-ranks (a "marathon" All Runs search rescoped to
two runs, and the tied Longest Run / Biggest Ascent stayed with the earlier
First Marathon holder); the improvement-history inspector lists strict-set
events newest-first with dates and values; the Fastest 10 km click-through
opens Trail 12K on Overview, seeks replay to the window start, and draws the
map overlay **split into two segments with nothing across the relocation**,
with the Charts band ending exactly at the 10 km window edge and the trace
breaking at the recording gap; selecting another workout clears the overlay
(and relaunch does not restore it — the session JSON carries no highlight);
City Marathon shows only Fastest Half Marathon / Fastest Marathon while First
Marathon shows only its tied ascent and longest-run chips; the Segments tab
appends attempted long windows shortest-first (Trail 12K through 10 km, City
Marathon through the marathon, Morning 3K none beyond the mile) and keeps its
selection and order while replay runs; ⌘⇧P is listed in Help → Keyboard
Shortcuts and arrow keys move the table selection with View Workout and the
history rows exposed as buttons; Records restores as the last workspace with
its persisted scope (session JSON is version 4). The one-off backfill was
exercised by stripping the `personalRecords` marker from all four snapshots
and relaunching: the records recomputed and were written back to disk with
their original window counts.

Not verified here and left unchecked: the inline backfill progress banner,
its Cancel, and resume — four synthetic fixtures backfill in milliseconds, too
fast to observe the transient banner, so the progress/Cancel/resume/no-churn
behaviour is left to `PersonalRecordsWorkspaceTests`; and a spoken VoiceOver
pass of the Records summary (keyboard reachability and the AX button/label
structure were inspected, but no VoiceOver spoken pass was run, per this
document's standing rule). Light appearance could not be exercised: this
scratch debug bundle rendered dark regardless of the system Light setting
(app-wide, not Records-specific); dark mode was verified thoroughly. The 720×500
pass is usable, with the trailing Workout column collapsing to "…" at that
exact minimum width.

## Route Quality Checklist

This checklist is intentionally unchecked. It defines the required GUI pass
and does not claim that any route-quality scenario has been manually verified.
Use only synthetic or explicitly private, ignored local workout files.

- [ ] Import a synthetic flat route containing altitude jitter.
- [ ] Confirm the flat route's elevation gain is small and believable.
- [ ] Confirm the elevation chart is visibly smoother while distance seeking
  remains aligned.
- [ ] Import a real-looking sustained climb and confirm the climb remains
  visible in the chart and analysis.
- [ ] Import a route containing one distant isolated coordinate spike.
- [ ] Confirm the map does not jump to or draw the rejected spike.
- [ ] Confirm total distance, derived speed, and pace do not include the
  rejected spike.
- [ ] Import a route containing a sustained coherent relocated cluster.
- [ ] Confirm the map shows disconnected route segments instead of a bridging
  line.
- [ ] Confirm replay jumps across the inferred gap without interpolating
  missing movement.
- [ ] Confirm summary, splits, notable climb/descent, comparison, chart, route
  colouring, and JSON/CSV/PNG exports agree on corrected elevation.
- [ ] Quit and relaunch; confirm corrected analysis, diagnostics, warnings, and
  normalization migration persist without repeatedly rewriting a current
  workout.
- [ ] Confirm GPX, TCX, FIT, JSON, replay, comparison, deletion, and export still
  work, and cancellation leaves no partially persisted import.

Packaged release smoke record (2026-07-14): the synthetic `sample-run` flow was
selected in the release bundle, the corrected elevation chart and accessible
metric controls were inspected, the native 2D/3D map toggle was exercised,
comparison with `realistic_5k_run` was entered and exited, and the JSON/CSV/PNG
Export menu actions were visible. The anomaly-specific route-quality scenarios
above remain unchecked.

## Pause-Aware Time Semantics Checklist

- [ ] Import or generate a workout with a visible pause.
- [ ] Confirm summary shows different Active and Elapsed durations.
- [ ] Confirm replay total equals Elapsed.
- [ ] Start replay and watch it enter the pause.
- [ ] Confirm the marker remains at the stop point until resume.
- [ ] Confirm distance and active time remain fixed while elapsed time advances.
- [ ] Confirm a kilometre split crossing the pause is still one kilometre split.
- [ ] Confirm split active pace excludes the pause.

## Recorded laps (FIT / TCX)

- [x] Import a TCX with two seamless manual/auto laps; map route stays continuous across the lap boundary.
- [ ] Confirm Active time does not lose time at a seamless lap boundary.
- [x] Open Splits and switch between Distance Splits and Recorded Laps.
- [ ] Confirm recorded lap trigger, distance, clocks, and pace; missing values show as unavailable.
- [x] Seek to each lap start; replay highlighting changes exactly at the next-lap start.
- [ ] Import a TCX with a pause as multiple Tracks; the true pause remains a route gap.
- [ ] Import a FIT with manual and auto-distance laps; triggers and source totals are retained.
- [ ] Export Recorded Laps CSV, combined CSV (with `# Recorded Laps`), and JSON; filenames distinguish laps from splits.
- [ ] Quit and relaunch; recorded laps persist. Open a legacy FIT/TCX snapshot and confirm no fabricated laps; reimport recovers them.
- [x] Compare two workouts with recorded laps (ordinal pairing only).
- [ ] Compare the paused run against an otherwise identical uninterrupted run.
- [ ] Confirm active and elapsed deltas are distinguished.
- [ ] Export JSON, CSV, and PNG and inspect the labels.
- [ ] Relaunch and confirm migrated analysis remains correct.
- [ ] Confirm GPX, TCX, FIT, map, charts, deletion, and persistence still work.

Recorded-lap manual record (2026-07-16): the packaged app imported a synthetic
two-lap TCX through the native open panel. The route remained continuous, the
Recorded Laps mode showed Manual and Distance triggers with distinct clocks and
paces, selecting lap 2 sought replay to 0:20 and changed the current-lap banner,
and comparison exposed ordinal pairing with a clear missing-laps state. Export,
FIT, multi-track pause, deletion, and legacy-snapshot checks remain unchecked
here. A packaged-app rebuild and relaunch retained the imported recorded laps.

## Moving/Stopped Estimate Checklist

These are required manual checks for this estimated GPS analysis; they are not
claims of completed verification.

- [x] Import a synthetic route with a 30-second stationary traffic-light stop.
- [x] Confirm Active exceeds Moving, Stopped equals Active minus Moving, and labels say estimated.
- [x] Replay through the stop: elapsed/active advance, moving holds, stopped advances, and state says Stopped.
- [x] Replay through an explicit recording pause: only elapsed advances and state says Paused.
- [x] Inspect a split containing the stop and verify active and moving pace are separately labelled.
- [x] Compare it with an otherwise identical uninterrupted run and inspect moving/stopped deltas and caveats.
- [x] Inspect JSON, CSV, and PNG exports for estimated moving/stopped labels and diagnostics.
- [x] Quit and relaunch to confirm the reanalysed snapshot persists without repeated migration.

Moving/stopped manual record (2026-07-15): the packaged app imported a synthetic
30-second traffic-light stop (elapsed/active 1:10, moving 0:40, stopped 0:30)
and showed the estimated labels. Replay showed `Stopped` while the moving clock
held; a synthetic explicit pause showed `Paused` while active, moving, and
stopped held. The split table exposed both active and estimated moving pace.
Comparison with an otherwise identical uninterrupted run showed `-0:30 less
moving`, `+0:30 more stopped`, and the estimate caveat. JSON, CSV, and PNG
exports were saved through the native panels and inspected for the estimated
fields. The packaged app was quit and relaunched; it loaded the reanalysed
snapshots without repeating migration.

## FIT Developer Data Checklist

Use only synthetic fixtures for automated checks. The one real-device check
below uses a file under `local-workouts/` (git-ignored) and is never
committed.

- [x] Import a synthetic FIT file with Stryd-style developer fields (power, ground time, vertical oscillation, plus one unknown field) and verify the Power chart, the Power replay badge, the Power splits column, and the Power & Running Dynamics panel all appear with sane values. *(2026-09-20)*
- [ ] Import the same workout and verify map coloring by Power: mode enabled, legend reads Lower → Higher with watts, no-data sections stay neutral, and the palette reads cool → warm yellow at higher effort.
- [ ] Verify warm-yellow power text (#FFD60A) is legible on the light appearance for the chart line, metrics badge, and splits column; power state is never conveyed by colour alone (labels and values accompany every colour use).
- [ ] Import a workout without power and verify the Power chart shows "No power data available", the Power map mode is disabled with an explanatory help string, the splits table omits the Power column (it is the only conditional column) while keeping every other column, and the dynamics panel is absent.
- [x] On a power workout, verify the splits table shows **both** Power and Elapsed Pace — power is additive and must not displace a column at normal width. *(2026-09-20)* **At 720pt width the table clipped: Power, HR and Elev were unreachable — [#146](https://github.com/shenghaoc/runplay-studio/issues/146); reachable at 720×552 since the 2026-09-23 record below.**
- [ ] Right-click the splits table header and verify the column menu appears; hide a column, confirm it disappears, relaunch the app and confirm the choice persisted; re-show it and confirm it returns.
- [ ] VoiceOver: the Power chart exposes a series-level descriptor (title, range, average, current value); the dynamics panel reads as combined label/value rows; nothing announces per replay frame.
- [ ] Export JSON and CSV from a power workout and confirm `averagePowerWatts`, `best20MinutePowerWatts`, the `runningDynamics` block, `Avg_Power_W` columns, and the `# Running Dynamics` section with explicit units; a plain workout omits them.
- [ ] Re-import the same developer-fields FIT file after editing nothing and confirm identity/duplicate behaviour is unchanged.
- [ ] On a real watch file whose dynamics are **native record fields** (Garmin writes 39/41/83/84/85, not developer fields), verify the dynamics panel shows them with sane units (GCT in hundreds of ms, VO in tens of mm, vertical ratio single-digit percent) and the provenance line reads "Running dynamics from the watch's native record fields."

### Real-device check (owner, local-only)

- [ ] Import one real FIT file from your own watch that carries developer fields (Stryd or Garmin running power), kept under `local-workouts/`. Confirm field names are recognized (or retained as unknown with sane units) and power values are plausible against the watch's own summary. Check the workout's developer-field notes for the **non-default scale or offset** diagnostic: developer values are decoded as `raw / scale - offset`, the sign every official Garmin SDK applies (see the developer-data section of [import-formats.md](import-formats.md)). The note fires only when a field declares scale ≠ 1 or offset ≠ 0, which is rare — if one appears, confirm the decoded value is sane, because those are the only cases where the official C++ and Swift SDKs would report different numbers.


### Manual pass 2026-09-20 — FIT power and running dynamics

Release-configuration bundle assembled from the #138–#141 stack plus the two
import fixes now on #143, launched with `RUNPLAY_LIBRARY_ROOT` against a
throwaway library. Fixtures: four synthetic files from
`FITMultiSessionFixtureBuilder` (Stryd-shaped power + dynamics; Garmin-style
native record power; 21 developer fields to trip the 16-field cap; no power at
all) and one real Garmin activity file from the owner's watch, kept in ignored
`local-workouts/`. No screenshot taken of the real file's map.

**Verified**

| item | result |
|---|---|
| Splits table shows Power **and** Elapsed Pace at normal width | PASS — all 11 columns render: Split, Distance, Elapsed, Active, Moving (est.), Moving Pace (est.), Active Pace, Elapsed Pace, Power, HR, Elev |
| Power chart renders, axis and units correct | PASS — yellow series, W axis, km domain; descriptor reads "Power chart. Distance in km. Power in W. Range 180.00 W to 329.00 W. Average 263.25 W…" |
| Power chart no-data state honest | PASS — no-power workout shows "No power data available", not an empty or zeroed chart |
| Dynamics panel opens, values unit-labelled | PASS — Average Power 263 W, Max Power 329 W, Avg Ground Contact Time 255 ms, Avg Vertical Oscillation 88.3 mm, Avg Vertical Ratio 8.0 % |
| Dynamics units sane | PASS — GCT in hundreds of ms, VO in tens of mm, vertical ratio single-digit percent |
| Provenance shown | PASS — developer-data case names the application id; real Garmin file reads "Power from the watch's native power field." |
| Best 20-min power present | PASS — 378 W on the 68-minute real file. Absent on the 10-minute fixtures, correctly: no 20-minute window exists |
| Honest empty state without dynamics | PASS — real file shows "Power & Running Dynamics (3 metrics)" with power rows only, no zeroed dynamics rows; no-power workout shows no panel at all |
| Developer-field truncation note | PASS — 21 developer fields produced "5 additional developer field(s) not retained (cap 16)." |
| Segment cards show mean power | PASS — fastest 400 m 423 W, fastest km 401 W, slowest km 292 W, biggest climb 354 W; power tracks effort as expected |
| Power not conveyed by colour alone | PASS — every power value carries a "W" unit and a labelled column or row |
| Power chart accessibility descriptor | PASS — series-level descriptor with title, range, average and current value (read from the accessibility tree, not heard) |

**Failed**

- **Splits table at 720pt width clips.** Power, HR and Elev are unreachable:
  horizontal scrolling stops before them. Eleven columns at fixed widths total
  840pt against roughly 700pt of usable content width. This predates Power —
  the table already exceeded that width — and a `min:ideal:` attempt did not
  compress the columns, so it was reverted rather than shipped. Note the window
  also has a 552pt minimum height, so "720x500" is not reachable; 720x552 is.
  Filed as [#146](https://github.com/shenghaoc/runplay-studio/issues/146)
  rather than holding the stack; `TableColumnCustomization` (hide a wide
  column) is the workaround.

**Not verified**

- Power map colouring (picker availability, legend, light/dark legibility) —
  the Route Color control is an in-window pop-up menu, which cannot be opened
  while the app is in the background, and it has no menu-bar equivalent.
- PNG export power mode availability — same reason.
- Replay badge and current-metrics panel *during playback* — the metrics bar
  was confirmed to show power at rest (255 W), but playback was not driven.
- VoiceOver spoken output — the chart descriptor and panel labels were read
  from the accessibility tree; **no spoken pass was performed and none is
  claimed**. Per-frame announcement behaviour during replay was not exercised.
- Registry recognition against real vendor data — see below.

**Real-file findings**

The owner's Garmin activity file (manufacturer 1, product 4315; 4,115 records,
8.44 km, 1:08:33) carries **no developer fields at all** — zero
`field_description` (206) and zero `developer_data_id` (207) messages. Power is
the native record field 7 on every record. So:

- recognised developer fields: none; retained raw: none; skipped: none
- non-zero offset diagnostic: did not fire, correctly — there are no developer
  fields to carry an offset
- power plausibility: median 349 W, mean 347 W, max 704 W over 68 minutes —
  plausible for the effort, and the GUI's Average 347 W / Max 704 W match the
  decoder exactly
- dynamics: **absent from the app**, though the file does record
  `vertical_oscillation`, `vertical_ratio`, `step_length` and `stance_time` on
  ~3,990 records as **native** record fields (profile 39, 83, 85, 41). The
  importer parses 12 record fields and none of those six, so a real Garmin
  watch's dynamics never reach the panel

**The recognition registry therefore remains unverified against real vendor
data.** It is exact-match against hard-coded spellings, so "Stryd Power",
"Power (w)" or "power_watts" would all miss. A Stryd or Connect IQ file is
still needed to exercise it.

### Manual pass 2026-09-20 (2) — FIT power and running dynamics, current #141 head

Independent re-verification on the rebased #141 head `e8beff3` (this is the
head the previous entry ticked twelve items on, but the fixture set and
`FITMultiSessionFixtureBuilder` paths were carried from an earlier session so
the numbers below replace the earlier ones for the acceptance items — do not
merge the two records). Bundle rebuilt from scratch via
`assemble-app-bundle.sh` at 2026-09-20 22:02; version `0.1.0` build 1; bundle
id `dev.local.runplay.fitgui`; throwaway library at `/tmp/runplay-fit-gui/library`.
Fixture used: one real Garmin activity file from the owner's watch
(`local-workouts/20044331971_ACTIVITY.fit`, kept in ignored `local-workouts/`).
No screenshot of the real file's map is shared or committed.

**Stage 2a acceptance — verified on the real Garmin file**

The previous 2026-09-20 pass recorded: "dynamics: **absent from the app** …
The importer parses 12 record fields and none of [39, 41, 83, 84, 85], so a
real Garmin watch's dynamics never reach the panel." Stage 2a was added
exactly for this. On this head:

| item | result on `e8beff3` |
|---|---|
| Native dynamics reach the Power & Running Dynamics panel | PASS — panel header reads "Power & Running Dynamics (7 metrics)" |
| Average Ground Contact Time | **347 ms** (present) |
| Average Vertical Oscillation | **78.0 mm** (present) |
| Average Vertical Ratio | **9.0 %** (present) |
| Average Step Length | **0.87 m** (present) |
| Stance Time Balance | **absent** — honest nil; field 84 is sentinel-only on this file, no fake zero |
| Per-metric provenance line | PASS — reads "Power from the watch's native power field. Running dynamics from the watch's native record fields." — both origins named independently |

The previous "dynamics absent from panel" finding on this real file is
**fixed on this head by stage 2a**.

**Also verified in-app on this head**

| item | result |
|---|---|
| Power chart on Charts tab | PASS — yellow line, W y-axis 0–1500, km x-axis 0–8 |
| Power chart accessibility descriptor | PASS — reads "Power chart. Distance in km. Power in W. Range 0.00 W to 685.20 W. Average 346.55 W. At current replay position 0.00 W. Distance 8.44 kilometres." |
| Chart-scale vs raw-max reconciliation | The chart descriptor's range max (685.20 W) is post-smoothing; the panel's Max Power (704 W) is raw — both are correct |
| Best 20-min power | PASS — 378 W (68-minute file so a 20-minute window exists) |
| Average / Max power in panel | PASS — 347 W avg, 704 W max — matches the decoder |
| Splits — Distance Splits | PASS — Power **and** Elapsed Pace columns both present at normal width (~1200pt); values 352 W, 373 W, 364 W, 340 W, 349 W, 328 W, 354 W, 294 W, 419 W across the 9 splits |
| Splits — Recorded Laps | PASS — **9 laps survive** (8 × 1.00 km distance + 1 × 0.44 km session end), monotonic, contiguous, elapsed 8:02 → 3:18. HR column populated 135–163 bpm. Recorded Laps has no Power column, which is expected (recorded-lap power is a non-goal). This confirms #143's lap-window fix on this real file's shape |
| Segments — mean power on cards | PASS — Fastest 400m 423 W, Fastest 1 km 401 W, Slowest 1 km 292 W visible; Biggest Climb, Fastest 1 mile, Fastest 5 km, Biggest Descent visible in the row |
| Non-default scale/offset diagnostic | Correctly did not fire — the real file has zero developer fields to carry a scale or offset (registry check therefore still unverified on real vendor data — same gap as the prior pass) |
| Summary stats sanity | 8.44 km, 1:08:33 elapsed, 151 bpm avg, 30 m elevation, 7:55/km moving pace, 8:07/km overall pace, Biggest single-run ascent 30 m, Fastest 1 km 7:03, Fastest 1 mile 7:13, Fastest 400m 6:46, Fastest 5 km 7:46 |

**Discrepancies from the earlier handover's stated numbers**

- Handover said "mean 346.6 W, 0–704 W" for power. Panel shows Avg 347 W / Max
  704 W (matches). Chart descriptor's post-smoothing range is 0.00 W – 685.20 W
  (the panel's raw max is the honest one for the workout).
- Handover said "9 recorded laps survive — eight 1-km distance laps + one
  sessionEnd lap". Verified: exactly that shape.
- Handover said "GCT 3,989 pts mean 346.9 ms". Panel shows 347 ms (rounded to
  integer for display).

**Not verified on this head, and why**

- **Route metric colouring by Power** (picker availability with Power offered
  only when power exists, legend, light/dark legibility, ramp reading cool →
  warm yellow, colour never the only channel). The Route Color control is a
  SwiftUI `Menu` popover attached to a map overlay button, so it can only be
  opened by clicking that button. In this session the display-scope input path
  (`computer_batch left_click`) was granted (`request_full_control` approved)
  and hover produced visible feedback (a Dock icon tooltip appeared under the
  cursor), but synthetic clicks did NOT register in RunPlay Studio's window or
  the Dock even after many attempts — repeated `left_click` at the correct
  point (verified by `cursor_position`) left the UI unchanged. `app_click` is
  explicitly refused for menu-presenting controls in background mode.
  Full-screen consent was granted but click delivery is unreliable at the
  macOS level in this session, so the item stopped after >2 attempts per the
  precondition rule.
- **PNG export power mode availability**. Same reason as Route Color — the
  export mode picker is an in-window pop-up menu with no menu-bar equivalent.
- **Replay playback with Power badge live during playback**. The Power badge
  in the current-metrics bar is visible at rest (reads "0 W" at replay
  position 0, as expected for the first record of this file). Play/pause was
  not driven in this session — playback controls are not exposed on the
  accessibility tree by title, and driving them would need the same
  display-scope click path that is broken here.
- **Splits at the minimum window width** (720x552). Window resize needs the
  same display-scope path that failed above. #146 is the pre-existing bug for
  this and its reproduction is documented on the previous pass — nothing this
  head added or removed changes that.
- **Spoken VoiceOver pass** — descriptor and labels were read from the
  accessibility tree (quoted above); **no spoken pass was performed and none
  is claimed**. Per-frame announcement behaviour during replay was not
  exercised.
- **Synthetic developer-field fixture** (developer provenance line, 16-field
  truncation note). The prior pass's "Stryd-shaped" and "21 developer fields"
  fixtures were produced by `FITMultiSessionFixtureBuilder` inside a running
  test, not as files on disk. Producing an on-disk developer-field FIT file
  would need a new small executable target linked against the test-only
  builder, which was out of scope for this pass.
- **Recognition registry against real vendor data** — same gap as before: the
  owner's file has no developer fields, so the exact-match spellings in the
  registry are still not exercised against a real Stryd or Connect IQ device.

**Explicit corrections to the earlier 2026-09-20 pass**

That pass reported "12 items PASS, 1 FAIL, 5 NOT VERIFIED" for what it called
"this head", but the head has since been rebased and stage 2a landed on top of
the code it exercised. The numbers above are what was measured on the current
head — do not carry the earlier "12 / 1 / 5" figures into any comment or
verdict tied to `e8beff3`.

### Manual pass 2026-09-20 (3) — keyboard-first retry of the unverified items

Fresh bundle rebuilt after two fixes on this session's head (`2c076e2`):

- `fix(a11y): power chart descriptor reports raw min/max/avg, not smoothed`
  — descriptor's Range/Average now match `RunSummary.maxPowerWatts` /
  `averagePowerWatts`. Verified on the real Garmin file: descriptor now
  reads **"Range 0.00 W to 704.00 W. Average 346.57 W."**, matching the
  panel's Avg 347 W / Max 704 W. Pass (2)'s "685.20 W" number was the
  smoothed-series max; that was the bug the fix removes.
- `fix(a11y): include Power in the Route Color button tooltip` — the outer
  `.help()` string on the Route Color button was written before PR 3 added
  the Power route color mode and was never updated. Sighted users hovering
  the button on a power workout read a summary of the modes; on this head
  the summary now includes "power", matching the popover's actual options.

**Newly verified in this pass**

| item | result |
|---|---|
| Replay playback with the live Power badge | PASS — driven from `Replay > Play/Pause` (menu-bar accessible; no display-scope required). Timeline advanced 0:00 → 0:42; the current-metrics bar's Power badge went 0 W → ~450 W as playback entered the running phase; every other tile ticks too (Elapsed 0:42, Active 0:42, Pace, Elev 16 m, HR ~120, Cad ~72). Replay > Seek Forward 5 also keyboard-accessible. |
| Splits table at 720x552 minimum window width | PASS — reproduces the pre-existing #146 behaviour and nothing on this head changed it. Resized via AppleScript (`set size of window 1 to {720, 552}`); with the sidebar visible the visible splits columns are `Elapsed, Active, Moving (est.), Moving Pace (est.), Active Pace` while `Elapsed Pace, Power, HR, Elev` fall off the right edge; a horizontal scroller exists but does not reach them. `TableColumnCustomization` (right-click header, hide a column) is still the workaround #146 documents. |
| Power chart descriptor consistency after the fix above | PASS — quoted verbatim above; panel and descriptor now name the same Max Power (704 W) |
| Route Color button tooltip mentions Power after the fix above | PASS — read from the accessibility tree on hover |

**Findings from the keyboard retry — file these**

- **Route Color popover has no menu-bar equivalent and no keyboard
  shortcut.** With the macOS default `AppleKeyboardUIMode = 0`
  (Full Keyboard Access off), Tab does not visit `.borderlessButton` menu
  buttons like Route Color, so a keyboard-only user cannot reach it. Enabling
  Full Keyboard Access (`defaults write NSGlobalDomain AppleKeyboardUIMode -int 2`)
  lets a real user Tab to the button and press Space to open the popover; the
  synthetic key events available from the background-mode tools here focused
  the button (blue ring appeared) but did not open its popover, so the retry
  cannot claim a keyboard drive of the popover itself.
  → File: add a menu-bar entry (e.g. `View > Route Color >` with all modes)
  or a keyboard shortcut so the picker is reachable from the default macOS
  keyboard state.
- **PNG summary card export has no menu-bar equivalent and no keyboard
  shortcut.** `ExportView` is a SwiftUI `Menu` in the toolbar (the pull-down
  next to the share button); with the same FKA-default caveat above, a
  keyboard-only user has no path to it. The `File` menu carries only
  `Import File…`, `Import Strava Archive…`, `Close`, `Close All` — no export
  path at all.
  → File: add `File > Export Summary (JSON)…`, `File > Export Summary Card
  (PNG)…`, `File > Export Route Replay (MP4)…` etc. so the pull-down's items
  are all reachable from the menu bar.

**Still not verified, and why**

- **Spoken VoiceOver pass** — enabling VoiceOver is a system-wide change
  that requires the user's action and would announce itself. Descriptor and
  labels have been read from the accessibility tree (quoted above); **no
  spoken pass was performed and none is claimed**.
- **Synthetic developer-field FIT fixture on disk** —
  `FITMultiSessionFixtureBuilder` is a test-target type, and the retry did
  not add a small executable to write one to disk. The Core test suite
  exercises the developer-provenance path in-process; verifying the panel's
  developer-field wording on a real live fixture is still open.
- **Recognition registry against real vendor data** — the owner's file
  still carries no developer fields, so the exact-match spellings in the
  registry are still not exercised against a real Stryd or Connect IQ
  device.

### Manual pass 2026-09-23 — workout detail at the 720×552 minimum (#146)

Release bundle of the #146 branch beside a release bundle of `main` (2006bfd)
for comparison, each launched with `RUNPLAY_LIBRARY_ROOT` against a throwaway
library. Fixture: one synthetic JSON run (2,401 points, 8.62 km) with heart
rate, cadence and power, so the Power splits column, the header's Avg HR and
every optional replay-dock metric are present. Driven with System Events and
`screencapture`; window size set by AppleScript and read back.

Root cause, measured rather than inferred: the splits table was never the
problem — hosted alone it stays inside its container and scrolls its full
width. The workout header's metric row and the side-by-side replay dock gave
the whole detail view an 848pt minimum, so beside the sidebar at 720pt every
tab was laid out wider than its column and clipped on **both** edges (on `main`
the Splits tab starts at "Elapsed"; Split and Distance are gone too).

| check | result |
|---|---|
| `main`, 720×552, Splits | FAIL (reproduces #146) — detail view clipped on both edges; header starts mid-"Elapsed" |
| Branch, 720×552, Splits, light | PASS — header, badges, tabs, table and dock inside the column; horizontal scroll over the table reaches Elapsed Pace, Power, HR, Elev |
| Branch, 720×552, Splits, dark | PASS — same layout; Power/HR/Elev colours legible |
| Branch, 1200×800, Splits, light and dark | PASS — all header metrics shown with the name truncated, as on `main`; dock labels on one line (on `main` they wrap letter by letter, e.g. "Elap / sed") |
| Branch, 720×552, Overview | PASS — map, header and dock inside the window |
| Branch, 720×552, Charts | Dock below the window bottom — pre-existing, same on `main`; filed as [#193](https://github.com/shenghaoc/runplay-studio/issues/193) |

Found and fixed during the pass: once the detail view fitted its column, the
standing-record badge row was squeezed to the column width and its chip titles
wrapped one letter per line, leaving the splits table no height. Chips are now
fixed-size and the row scrolls when they do not fit. At 720×552 the table shows
about two rows and scrolls vertically; the header metrics, badges and dock
metrics scroll horizontally.

Also found: a JSON file whose `metadata` lacks a required key is reported as
"Imported but could not save to your library" — filed as
[#192](https://github.com/shenghaoc/runplay-studio/issues/192).

Not covered: VoiceOver was not run, and the sidebar was not dragged to its
320pt maximum.

## FIT Import Checklist

Use synthetic FIT fixtures only. These are manual checks to perform in a GUI
session; they are not claims of a completed manual pass.

- [ ] Import a compressed-timestamp FIT running activity and verify its route, duration, replay, and charts.
- [ ] Import a FIT activity with timer stop/start events and verify the map and replay do not bridge the paused gap.
- [ ] Import enhanced altitude/speed values and confirm they are not truncated.
- [ ] Confirm a non-running FIT activity shows a clear import error.
- [ ] Cancel a large FIT import and confirm it is neither displayed nor persisted after relaunch.

## Multi-session FIT import (synthetic)

Use **synthetic** FIT fixtures only — never commit real workout files. These
are manual checks to perform in a GUI session; they are not claims of a
completed manual pass.

1. Import an ordinary one-session FIT file → **no** review sheet appears.
2. Import a legacy sessionless FIT file → **no** review sheet appears.
3. Import a FIT file with two running sessions → **Import FIT Sessions** opens.
4. Confirm both sessions are listed in FIT source order with date, sport,
   elapsed, distance, GPS points, laps, and status.
5. Import both; confirm two workouts appear in the library.
6. Confirm the newest imported session opens after commit.
7. Replay each and inspect route separation — no shared points.
8. Inspect timer pauses per session; a pause in one must not split the other.
9. Inspect recorded laps per session; no lap appears twice.
10. Reimport the exact same file → both sessions show **Already imported**.
11. Rename the file and reimport → still **Already imported**.
12. Import a running-plus-cycling FIT file → running selected, cycling visible
    but disabled with an explanation.
13. Import a file with one valid and one malformed session → the valid session
    commits and the malformed one is reported.
14. Cancel during processing → nothing commits.
15. Keyboard-only pass: Tab through the table, toggle Include with Space, use
    Select All Importable / Select None, Return to import, Escape to cancel.
16. VoiceOver: row summaries read name, sport, timing, counts, and status; the
    selected count is announced; no announcement spam during progress.
17. Narrow window, light/dark appearance, and increased contrast: status text
    stays readable and no state is signalled by colour alone.
18. Quit and relaunch → library and selected workout persist.
19. Confirm tags, smart collections, heatmap, and comparison still work.
20. Import an ordinary FIT file from a synthetic Strava archive → unchanged.
21. Put a multi-session FIT file inside a synthetic Strava archive → that entry
    is reported as failed; **no** nested review sheet appears.

Focused pre-merge smoke record (2026-07-25), packaged
`.build/artifacts/RunPlayStudio.app`, synthetic fixtures only:

- **Import File…** (⌘I) exposed the review sheet for a two-session FIT file;
  no separate multi-session command exists in the File menu.
- The sheet listed both sessions in FIT source order with Include, Session,
  Date, Sport, Elapsed, Distance, GPS Points, Laps, and Status columns.
- **Import 2 Runs** committed both; the library went 7 → 9, the newer session
  (20:23) was selected, and the two workouts had distinct routes and durations
  (5.10 km / 19:30 and 4.35 km / 14:30).
- The per-session source-timing warning fired on the paused session only.
- Reimporting the same file, and a renamed copy of it, showed **Already
  imported** for both sessions with **Import 0 Runs** disabled.
- A running-plus-cycling file showed `Importable 1` / `Unsupported 1`, with the
  cycling row visible, disabled, and labelled **Unsupported sport**; importing
  brought in the running session only.
- Return triggered the default **Import N Runs** action.
- Deleting the imported workouts restored the library to its original state.

Final pre-merge follow-up (2026-07-26), using the current packaged artifact:

- Escape dismissed both ready and duplicate review sheets without mutating the
  library; Return invoked the default import action.
- The accessibility tree exposed the selected-count summary, complete row
  summaries (name, sport, date, elapsed time, distance, GPS points, laps, and
  textual status), checkbox state/help, and every action.
- Exact reimport showed two disabled **Already imported** rows and a disabled
  **Import 0 Runs** action.
- A running-plus-cycling fixture exposed one selected running row and one
  disabled cycling row with the explanation **Cycling sessions are not
  supported**; only the run committed.
- Completion reports and the 7 → 9 / 9 → 10 library transitions matched the
  committed workouts. The three synthetic workouts were then deleted, restoring
  the original seven-run library.

A spoken VoiceOver pass, increased-contrast pass, and appearance variants remain
part of the broader release checklist; they are not substitutes for the
packaged-app and accessibility-tree checks above.

## Watch-folder import (synthetic)

Use **synthetic** fixtures only — never point a watch folder at a directory of
real private workout files, and never commit what lands in one. These are
manual checks to perform in a GUI session; they are not claims of a completed
manual pass.

### Prep

Create three throwaway directories and keep a few synthetic files handy (the
Strava archive fixtures above, or any synthetic `.gpx`/`.tcx`/`.fit`/`.json`
run):

```bash
WATCH_ROOT="$HOME/watch-folder-manual"
mkdir -p "$WATCH_ROOT/live" "$WATCH_ROOT/existing" "$WATCH_ROOT/removable"
```

Generate a file slowly **only if reproducing the settle behaviour by hand** —
the slow-write case is automated (item 9), so this script is a convenience, not
a required step:

```bash
# Writes a synthetic GPX in 1 KB slices over ~10 s; the watcher must not
# import it until the writes stop.
python3 - <<'PY'
import time, pathlib
src = pathlib.Path("FIXTURE.gpx").read_text()   # any synthetic GPX
out = pathlib.Path.home() / "watch-folder-manual/live/slow.gpx"
with out.open("w") as f:
    for i in range(0, len(src), 1024):
        f.write(src[i:i + 1024]); f.flush()
        time.sleep(0.5)
PY
```

### Settings pane and folder lifecycle

1. **File → Watch Folders…** opens Settings on the Watch Folders pane.
2. **Add Folder…** on `live` → it appears in the list, unpaused, watching.
3. **Import Existing Files Now** on a folder pre-populated with `existing`
   files → they import without waiting for the settle interval.
4. Set a default tag on one folder, drop a new file in, confirm the imported
   workout carries that tag and that the tag is created once, not duplicated.
5. **Pause** → dropping a file in does nothing. **Resume** → the next poll
   picks it up.
6. **Remove** a folder → it stops scanning at once and the directory is no
   longer touched (verify with `fs_usage` or by moving the folder away).
7. Quit and relaunch → the folder list, paused flags, default tags, and
   ledgers all persist; previously imported files are **not** re-imported.

### Detection, settle, and dedupe

8. Drop one synthetic GPX into `live` → it imports within a few seconds
   (DispatchSource early wake), not only at the next poll.
9. [AUTOMATED] ~~Run the slow-write script → the file is **not** imported
   while it grows, then imports once the size and modification date are stable
   across two probes.~~ Covered by
   `WatchFolderScannerTests.testSettleWithholdsSlowlyWrittenFileUntilStable`,
   which writes a file in slices with pauses, probes the scanner mid-write, and
   asserts it stays unsettled while the size keeps changing and settles once it
   has been stable for the interval. The manual script above remains available
   for eyeballing the end-to-end path, but this behaviour no longer needs a hand
   pass.
10. Import the same content again under a new filename (`cp a.gpx b.gpx`) →
    one **Skipped — already imported** row appears in Recent Imports and no
    second workout is created.
11. Leave an already-processed file alone across several poll cycles → the
    Recent Imports list does **not** accumulate repeated skip rows.
12. Drop a corrupt/unsupported file (`.gpx` with garbage bytes, a `.txt`, a
    hidden `.a.gpx`, a directory named `sub.gpx`) → one **Failed** row with a
    readable reason for the corrupt file; the rest are ignored silently, and
    the corrupt file is **not** retried on every subsequent scan.
13. Drop a file larger than the 100 MB product limit → a definitive **Failed**
    row naming the size limit; no repeated retries.
14. Confirm files in a **subdirectory** of a watched folder are never imported
    (watching is non-recursive).
15. Delete an imported workout from the library → it does **not** come back on
    the next scan (the ledger is content identity, not library state).

### Multi-session FIT review

16. Drop a multi-session `.fit` file in → a **non-modal** banner appears; no
    sheet steals focus and no alert blocks the window.
17. Activate the banner → the existing **Import FIT Sessions** review sheet
    opens with the queued container; import → workouts commit, the banner
    clears, and the file is ledgered.
18. Dismiss the banner without importing → the file stays queued and is not
    re-announced on every poll.
19. Drop a single-session `.fit` file in → it imports directly with **no**
    review sheet and no banner.
20. Quit and relaunch with a queued review still pending → the banner returns
    from the persisted pending-review state.

### Recent Imports panel

21. Open the toolbar **Recent Imports** popover → per-file rows show folder,
    filename, status (imported / skipped / failed / awaiting review), time,
    and failure detail.
22. **Reveal in Finder** on a row opens the containing folder with the file
    selected.
23. Confirm the list is bounded (oldest rows drop off) and that it is empty
    after relaunch — recent rows are in-memory only, the ledger is what
    persists.
24. Confirm a failure produces **no** modal alert anywhere; the only surfaces
    are the panel row and a single VoiceOver announcement.

### Environment scenarios

25. **Mounted device volume** (a Garmin/Fenix-style `Volumes/GARMIN/Activities`
    directory, or any removable volume): add it while mounted, copy a file in,
    confirm import. Then **eject the volume while watching** → no crash, no
    modal alert, exactly **one** readable failure row in Recent Imports (not one
    per poll), and the Settings pane shows that folder as **Unavailable —
    watching resumes if it returns** with a warning icon instead of a green
    "Watching" status. **Remount** → watching resumes automatically without
    re-adding the folder, the Unavailable status clears, and a new file copied
    in imports. Confirm no Recent Imports row is added merely because the folder
    came back (recovery is folder state, not an import).
26. **Synced folder** (Dropbox / iCloud Drive / Google Drive): add the local
    synced directory and confirm a file that lands as a partial download plus
    its `.partial`/`.icloud` companion imports exactly once, after the sync
    client finishes writing. Confirm the temporary companion files are never
    imported — hidden `.`-prefixed companions and non-supported extensions such
    as `.partial` and `.icloud` are skipped — and that no duplicate appears when
    the sync client renames the finished file into place.
27. **Folder removed while watching**: `rm -rf` or move away a watched folder
    with the app running → no crash, no alert storm, one readable failure row,
    and the folder reads **Unavailable** in the Settings pane rather than
    "Watching". Recreate the directory at the same path → watching resumes on a
    later poll without re-adding the folder. Then remove it again and confirm a
    **second** row appears (one per transition, not one per poll). Finally,
    confirm a **paused** folder whose directory is removed is never reported
    unavailable, because pausing stops access deliberately.
28. Confirm no network activity occurs beyond the existing MapKit basemap loads
    (Little Snitch or `nettop`) while watching, importing, and revealing.
29. Confirm the watched folder's source files are never modified, moved, or
    deleted by any of the above.

### Accessibility and appearance

30. Keyboard-only: reach the Watch Folders pane, add/remove/pause folders,
    trigger **Import Existing Files Now**, open the Recent Imports popover, and
    activate a row's Reveal in Finder without a pointer. Escape closes the
    Recent Imports popover. The review banner is dismissed by tabbing to its
    **Dismiss** button and pressing Space — it deliberately does not take
    focus, so it never traps keyboard navigation; confirm focus order passes
    through the banner and back into the main content.
31. VoiceOver: folder rows read name plus status as text (**Watching**,
    **Paused**, or **Unavailable — watching resumes if it returns**); the
    default tag is a separate labelled field ("Default tag for <folder>"), and
    the Pause/Resume button names the folder it acts on. Recent Imports rows
    read status as **text** ("Imported", "Skipped, already imported", "Failed",
    "Waiting for review") followed by file and folder — never colour or icon
    alone, since the status icon is hidden from accessibility. A completed
    import and a failure each produce exactly one announcement (no per-poll
    spam), and folder unavailability is announced once per transition.
32. Light/dark, Increase Contrast, and Reduce Transparency: status colours stay
    legible and every status remains distinguishable without colour.
33. Narrow window: the settings pane and the Recent Imports popover stay
    readable and do not clip rows or buttons.

### Manual pass 2026-09-23 — watch-folder import on `main`, after merge

**This pass ran after the feature shipped.** #167–#170 and #156 merged
before any GUI pass, so this record verifies shipped code on `main` (the
merge of #156), not a branch. Failures are filed as issues against `main`
(#175–#183), not reverted.

Setup: release build assembled with `scripts/assemble-app-bundle.sh` under a
separate bundle identifier, throwaway `RUNPLAY_LIBRARY_ROOT`, synthetic GPX
fixtures (one generated loop per file) except the real-history check below.
macOS 27, light appearance, Keyboard navigation **off** on the test Mac
(`AppleKeyboardUIMode = 0`). Screenshots were taken and kept out of the
repository.

Result key: **PASS** verified by hand; **FAIL** observed failing (issue
linked); **NOT VERIFIED** could not be exercised as written; **NOT RUN** not
attempted. Only PASS rows count as ticked.

| # | Result | Evidence |
| --- | --- | --- |
| 1 | FAIL — #175 | File → Watch Folders… opens nothing; the app menu's Settings… (⌘,) works. |
| 2 | PASS | Added folder listed, unpaused, "Watching"; `watch-folders.json` written under the library root. |
| 3 | NOT VERIFIED — #179 | Adding a folder already imports its existing files (1 → 5 workouts before the button was touched), so the button has nothing left to do. |
| 4 | FAIL — #177 | A tag set while the folder was watching was not applied to the next two imports; it applied only after pause/resume. The "created once" half passes: 1 tag, reused. |
| 5 | PASS | Per-folder Pause: a dropped file stayed unimported for 15 s; Resume imported it. Master switch problems are #180. |
| 6 | FAIL — #176 | No way to remove a folder by pointer, keyboard, or VoiceOver. |
| 7 | PASS | After relaunch: folders, paused flags, default tags, and ledgers identical; library count unchanged (nothing re-imported). |
| 8 | PASS | Imported 4 s after the drop. With a 5 s poll and 2 s settle, this does not prove the DispatchSource early wake. |
| 9 | Automated | Not re-run by hand. |
| 10 | PASS | One skipped row, no second workout. The row's status is icon-only on screen; "Skipped, already imported" is spoken by VoiceOver only. |
| 11 | PASS in session | One skip row across many polls. Re-reported after each relaunch — #182. |
| 12 | PASS | Garbage `.gpx`: one Failed row with a readable reason, ledgered, not retried. `.txt`, hidden `.a.gpx`, and a `sub.gpx` directory ignored. |
| 13 | PASS in session | 110 MB file: one Failed row naming the 100 MB limit. Re-reported after each relaunch — #182. |
| 14 | PASS | File in a subdirectory never imported. |
| 15 | PASS | Deleted a watch-imported workout; source file untouched; not re-imported over ~5 polls. |
| 16–20 | NOT RUN | No synthetic multi-session FIT fixture was at hand. |
| 21 | PASS (content) — #178 | Popover rows show folder, file, status icon, time, and failure detail. Its toolbar button has no visible icon. |
| 22 | PASS | Reveal in Finder opened the folder with the file selected. |
| 23 | PASS (bound) / FAIL — #182 | 55 new files: the list kept exactly the 50 newest. After relaunch the list was not empty (over-limit and duplicate rows re-reported). |
| 24 | PASS | No modal alert from any watch-folder path in the whole session. |
| 25 | PASS (simulated volume) — #181 | A `GARMIN` disk image stood in for a watch (no device attached): add, import, eject → "Unavailable — watching resumes if it returns", one row, one announcement; remount → resumed, new file imported, no recovery row. A later relaunch **re-mounted** the ejected image. |
| 26 | PASS (partial) | No Dropbox on the test Mac; used iCloud Drive with the owner's approval and synthetic files only. A slowly written `.partial`, renamed into place, imported exactly once and the companion was never ledgered. A real `brctl evict` left the file dataless; the app did not force a download, re-import, or report it. A true download from a second device was not exercised. The test folder was deleted afterwards. |
| 27 | PASS — #181 | Moved away: one row, "Unavailable"; recreated: resumed with no recovery row; removed again: a second row; paused folder removed: stayed "Paused", no row. Separately, a later re-activation silently followed the moved-away directory. |
| 28 | PASS (app process) | `nettop` showed no flows for the app process during an import (12 × 1 s). MapKit tiles load in a system process and were not measured. |
| 29 | PASS | Every watched synthetic file byte-identical to its original; real-history copies unchanged (SHA-256). |
| 30 | NOT VERIFIED — #183 | Keyboard navigation was off, so Tab could not reach buttons. Observed: Escape did not close a pointer-opened popover. |
| 31 | PASS (partial) | VoiceOver read "live, Watching", "Default tag for live, edit text", "Pause watching live, button"; rows "Imported, ‹file›, ‹folder›" and "Failed, ‹file›, ‹folder›, ‹reason›"; unavailability announced once ("Watched folder Activities is unavailable. Watching resumes if it returns."). Per-import and per-failure announcements were not captured. |
| 32 | NOT RUN | Light appearance only. |
| 33 | PASS (popover) | At 720×552 the popover stays readable, with no clipped rows or buttons; long failure details truncate at two lines. The Settings window is fixed at 900×648 and cannot be narrowed. |

**Real history (owner-requested).** The three real files in the ignored
`local-workouts/` (2 FIT, 1 TCX) were **copied** to a scratch folder outside
the repository and that copy was watched, never the original directory.
Result: 2 imported; 1 FIT was rejected with "No valid GPS coordinates found in
FIT file" (it has no GPS track), ledgered and not retried. The copies'
SHA-256 sums were unchanged afterwards. No file names or contents from them
are recorded here.

**Plain assessment.** The import engine is sound: settle, dedupe, failure
rows, unavailability, recovery, reveal, and source-file safety all behaved.
The management surface around it is not. The File-menu entry is dead (#175).
A folder cannot be removed once added (#176). Adding a folder bulk-imports
everything already in it (#179). A default tag can silently not apply (#177).
The popover's only button is invisible (#178). Together that makes adding a
watch folder an irreversible bulk import that the user cannot easily see
into. #175 and #176 should be fixed before anyone is pointed at this feature.

## DEM elevation correction (synthetic)

Use **synthetic** tiles and routes only — never commit real tiles, real runs,
or anything derived from them. These are manual checks to perform in a GUI
session on the ad-hoc-signed bundle from `scripts/assemble-app-bundle.sh`
(the bookmark behaviour is only meaningful in the build that ships); they are
not claims of a completed manual pass.

### Prep

Writes a 3×3 block of flat 612 m Terrarium tiles at zoom 13, a copy missing
the eastern tile the route enters, and a flat 4 km GPX with a noisy recorded
altitude that crosses one tile edge (standard library only; nothing is
downloaded):

```bash
python3 - <<'PY'
import math, pathlib, random, shutil, struct, zlib
root = pathlib.Path.home() / "dem-manual"
Z, LAT, LON = 13, 46.44, 7.30

def tile_of(lat, lon):
    n = 2 ** Z
    return (int((lon + 180) / 360 * n),
            int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n))

def terrarium_png(height, size=256):
    v = height + 32768
    pixel = bytes((int(v // 256), int(v % 256), int((v - math.floor(v)) * 256)))
    raw = b"".join(b"\0" + pixel * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

cx, cy = tile_of(LAT, LON)
for x in range(cx - 1, cx + 2):
    for y in range(cy - 1, cy + 2):
        out = root / "tiles" / str(Z) / str(x) / f"{y}.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(terrarium_png(612))
shutil.copytree(root / "tiles", root / "partial", dirs_exist_ok=True)
(root / "partial" / str(Z) / str(cx + 1) / f"{cy}.png").unlink()

random.seed(965)
noise, points = 0.0, []
for i in range(801):  # 4 km east at 5 m per point, one point every 2 s
    noise = max(-8.0, min(8.0, noise + random.uniform(-1.5, 1.5)))
    lon = LON + (i * 5) / (111_320 * math.cos(math.radians(LAT)))
    t = f"2026-09-01T07:{(i * 2) // 60:02d}:{(i * 2) % 60:02d}Z"
    points.append(f'<trkpt lat="{LAT}" lon="{lon:.6f}"><ele>{600 + noise:.1f}</ele><time>{t}</time></trkpt>')
(root / "flat-noisy.gpx").write_text(
    '<?xml version="1.0"?><gpx version="1.1" creator="synthetic"><trk><trkseg>'
    + "".join(points) + "</trkseg></trk></gpx>")
print("tiles:", root / "tiles", "partial:", root / "partial", "gpx:", root / "flat-noisy.gpx")
PY
```

### Settings and folder

1. **Settings → Elevation** without a folder: the pane says runs keep their
   recorded elevation; Correct new imports and the library button are disabled.
2. **Choose Folder…** on `~/dem-manual` (no zoom directories) → refused with
   the expected `z/x/y.png` layout; nothing is saved.
3. **Choose Folder…** on `~/dem-manual/tiles` → folder name, Zoom 13, Tile
   size 256 pixels; Correct new imports is on.
4. Quit and relaunch → the folder is still chosen and ready (no
   "could not be opened" line). Move `tiles` to another folder on the same
   disk and relaunch → still ready, because the bookmark follows the move.
   Delete it (the prep script regenerates it) and relaunch → the pane reports
   that it could not be opened; regenerate it and choose it again.

### Imports and per-run commands

5. Import `flat-noisy.gpx` → VoiceOver announces the import with "Elevation
   corrected from DEM tiles covering 100% of the route, replacing recorded
   altitude from an unstated sensor." Overview ascent is 0 m.
6. **Charts → Elevation**: a flat line at 612 m; the note reads "Source: DEM
   tiles" and the plain sentence that DEM replaced recorded altitude from an
   unstated sensor.
7. **Workout ▸ Use Recorded Elevation** → the item is checked, the chart shows
   the noisy recorded line, ascent returns to its noisy value (write both
   numbers down), the note says correction is off, and Workout ▸ Correct
   Elevation is disabled. Uncheck it → corrected again.
8. Choose `~/dem-manual/partial` in Settings, then **Workout ▸ Correct
   Elevation** → the chart breaks at the tile edge and the eastern part is
   dashed, with the legend "Dashed sections use recorded altitude where no
   DEM tile covers the route."; the note reports the coverage percentage and
   "1 tile is missing from the folder"; ascent does not jump by the offset
   between 612 m and the recorded ~600 m.

### Library pass and batch imports

9. Turn Correct new imports off, import two more synthetic runs, turn it back
   on → the button reads "Correct Elevation of 2 Runs". Run it → progress with
   the current run's name, then a one-line summary that VoiceOver also reads.
   On a larger synthetic library, Cancel mid-pass → runs corrected so far stay
   corrected; running it again resumes.
10. Import a synthetic Strava archive and a synthetic multi-session FIT with
    correction on → each report shows the "DEM elevation for N runs" line and
    per-run coverage in Details.
11. Drop a synthetic GPX into a watched folder → its Recent Imports row shows
    the elevation line in secondary text and speaks it.

### Accessibility and appearance

12. Every Elevation pane control is reachable by keyboard and labelled; the
    folder status is text, not colour alone.
13. VoiceOver on the Elevation chart note reads the source, the legend, and
    the notes as one element; the audio graph summary ends with the source.
14. The Workout menu items are reachable from the keyboard (⌃F2) and Use
    Recorded Elevation announces its state.
15. Dark mode and the 720×552 minimum window: the note wraps without clipping.

### Real-data acceptance (owner, local-only)

On one of your own flat runs, with tiles you supply that cover it: record the
ascent with **Use Recorded Elevation** checked, then unchecked (DEM), and report
only the two numbers. Never commit the file, the tiles, or anything derived from
them.

## All Runs Library Checklist

Use synthetic fixtures only. Do not claim unperformed GUI scenarios.

- [ ] Open **All Runs** from the Library sidebar (or Workout → All Runs / ⌘⇧L).
- [ ] Confirm the sidebar does not list every workout; Favourites / Recent are capped.
- [ ] Search by name, notes, year, source, and device.
- [ ] Exercise date, source, favourite, and data filters; Clear Filters / Clear Search.
- [ ] Exercise each sort mode; missing dates/pace sort after valid values.
- [ ] Favourite / unfavourite a persisted workout; confirm sidebar Favourites update.
- [ ] Open **All Favourites…** after applying other search/filters; confirm it shows the complete favourites collection.
- [ ] Confirm bundled demos cannot be favourited as persistent library entries.
- [ ] Edit name and notes; search finds the new notes; empty name restores fallback display.
- [ ] Quit and relaunch; favourites and metadata persist for library workouts.
- [ ] Import one file and a Strava archive; All Runs refreshes once after commit.
- [ ] Delete a favourite; manifest favourite set no longer contains it.
- [ ] Open comparison, heatmap, and PNG export; none inherit All Runs filters.
- [ ] Create tags; reject a folded duplicate name; rename/recolor; assign tags; search by tag name.
- [ ] Filter by any/all selected tags and untagged only.
- [ ] Multi-select runs and bulk-add/remove tags; verify tri-state mixed tags.
- [ ] Delete an assigned tag; confirm workouts remain and collections drop that criterion.
- [ ] Save current query as a smart collection; open from sidebar; confirm Modified/Revert/Update.
- [ ] Return to All Runs and confirm the prior manual query is restored.
- [ ] Import a matching workout; confirm dynamic collection membership updates.
- [ ] Quit/relaunch; tags, assignments, collections, favourites, and selection persist.
- [ ] Keyboard navigate tags/collections; inspect VoiceOver labels; light/dark tag colors.
- [ ] Keyboard: select rows, Return to open, Delete with confirmation, focus search.

## Window and application-session restoration checklist

Use the packaged app from `./scripts/package-demo.sh` and synthetic repository
fixtures only. Native macOS owns frame placement and restoration; the JSON
session file owns logical workspace state. Do not mark the relaunch or display
items complete without performing them on the supported desktop target.

- [x] Confirm the packaged app presents one stable-ID main `Window` and does not
  create an independent second workspace through New Window.
- [x] Change the workout tab and All Runs destination; confirm the bounded
  session JSON changes without route points, result IDs, or map/cache data.
- [x] Move and resize the main window, quit normally, and relaunch; confirm
  native frame placement, size, minimise, zoom, and full-screen behavior.
- [x] Change sidebar visibility, quit, and relaunch; confirm visibility returns
  without persisting an exact sidebar width.
- [x] Quit from a workout, All Runs, smart collection, Personal Heatmap, and
  valid comparison; confirm each durable destination and substate restores.
- [x] Set replay position and speed, start playback, quit, and relaunch;
  confirm position/speed return paused with no active timer.
- [x] Modify a smart collection without updating it, relaunch, and confirm
  Modified/Revert/Update behavior plus return to the prior manual query.
- [x] Delete a referenced workout or smart collection, relaunch, and confirm
  safe fallback without an alert or dangling ID.
- [x] Open importer, export, editor, manager, confirmation, and error UI,
  relaunch, and confirm no transient presentation returns.
- [ ] Repeat with a secondary display attached, then unavailable, and confirm
  native restoration keeps the window on a visible display.

Packaged-app smoke record (2026-07-25): the release app was rebuilt warning
clean and inspected in an unlocked desktop session with Computer Use. The
singleton scene exposed one stable-ID main window and no New Window command.
Charts, All Runs, the manual query, hidden-sidebar state, a modified smart
collection, Personal Heatmap at Broad resolution, and a 2.20 km comparison
survived normal quit/relaunch. Replay at 2.0× checkpointed while playing and
restored its position and speed paused. Deleting a temporary referenced workout
and smart collection produced a safe durable fallback.

The native Window menu moved and resized the main window from 1200×766 to
757×553; normal quit/relaunch restored the tiled placement and 756×552 frame,
allowing for native border normalization. Minimise, zoom, and full-screen
transitions remained native. Forced relaunches with the importer, export save
panel, metadata editor, smart-collection manager, delete confirmation, and
invalid-FIT error open returned only the durable main workspace; no transient
presentation returned. The host reported one connected display, so the
secondary-display item remains hardware-gated and the README states that
boundary.

## Persistent Workout Library Checklist

Use a synthetic fixture and confirm the original fixture checksum before and
after the flow.

- [x] Launch with an empty user library and confirm bundled demos appear.
- [x] Import a synthetic TCX workout through the sidebar Import control.
- [x] Quit and relaunch; confirm the imported workout returns selected.
- [x] Confirm bundled demos are not inserted alongside the persisted library.
- [x] Confirm Overview, Charts, replay, and comparison remain reachable.
- [x] Delete the imported workout through the destructive confirmation.
- [x] Quit and relaunch; confirm the deleted workout remains deleted and demos
  return as the empty-library experience.
- [x] Confirm the original TCX fixture checksum is unchanged.
- [x] Capture the empty, imported/restored, and post-delete states for the final
  HIG/UX audit.

Persistence dogfood record (2026-07-11):

- The packaged SwiftPM app launched with the two bundled demos when the user
  manifest was empty.
- `sample-run.tcx` imported through the native file picker, survived relaunch as
  the sole selected workout, and remained usable in Overview, Charts, and replay.
- The native delete confirmation stated that only RunPlay Studio's stored copy
  would be deleted. After deletion and relaunch, the imported workout stayed
  deleted and the bundled demos returned.
- The bundled comparison flow remained reachable after the persistence cycle.
- The synthetic fixture SHA-256 remained
  `a7b2f86e58832d3316fd2aa0cf89c648fbf653267f7f45f808b46a101fe06dba`.
- Screenshots are retained outside the repository in the final-gate audit
  artifact directory `pr23-persistence-audit`.
## Privacy Checklist Before Commit

- [x] Keep private workout files untracked or ignored.
- [x] Run `git status --short`.
- [x] Run `git diff --cached --name-status` after staging.
- [x] Verify no personal GPX, TCX, FIT, JSON, screenshots, or private exports
  are staged.
- [x] Use explicit `git add <path>` rather than `git add -A`.
- [x] Keep committed fixtures and demo assets synthetic or anonymized.
- [x] Store private workout files under `local-workouts/` or `private-workouts/`.
- [x] Note: `activity_*.tcx` and `activity_*.fit` are gitignored for local dogfooding.
- [x] Note: `watch-folders.json` (folder display names, security-scoped bookmark
  bytes, per-folder SHA-256 ledger) lives in `Application Support/RunPlayStudio/`
  and is never a repository artifact; point watch folders only at synthetic
  fixture directories during manual passes.
- [x] See `docs/private-data.md` for the durable private-data policy.

## Route Comparison Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs and, when available, a local user-provided TCX
  file. Do not commit private workout data.

Checklist:

- [x] App launches with at least two workouts loaded.
- [ ] Single-run map toggles between 2D and 3D before entering comparison.
## Route-Aware DTW Comparison Checklist

Use only synthetic or approved repository fixtures. Route-Aware alignment is
GPS shape matching, not road-level map matching.

- [ ] Compare two identical-geometry routes with different sample rates; both Distance and Route-Aware work; Route-Aware quality is high.
- [ ] Move the matched-route slider; P and C markers use mapped distances that may differ.
- [ ] Confirm matched-section elapsed/active clocks exclude unmatched prefixes.
- [ ] Mild GPS noise and a short detour remain available.
- [ ] Small start/end offsets are tolerated within policy.
- [ ] A recording gap produces separate alignment/chart blocks (no bridge).
- [ ] Completely different routes: Route-Aware unavailable; Distance still works.
- [ ] Opposite-direction runs: Route-Aware unavailable with clear explanation.
- [ ] Loop with large rotated start: limited/unavailable with explicit copy.
- [ ] Rapid peer switching does not show stale aligned markers.
- [ ] Quit with Route-Aware selected; relaunch recomputes alignment and clamps progress.
- [ ] Delete the comparison workout; comparison falls back safely.
- [ ] Keyboard-only: alignment picker, Use Distance action, matched-route slider.
- [ ] VoiceOver: mode, quality, coverage, progress, mapped distances, separation.
- [ ] Distance mode retains existing marker, metric, chart, split, and lap behaviour.
- [ ] Splits/laps headings remain “not route-aligned” under Route-Aware.

- [x] Open Compare view from the toolbar.
- [x] Select a primary workout.
- [x] Select a comparison workout.
- [x] Verify the current primary workout is not offered as its own comparison.
- [ ] Verify summary delta cards distinguish Active Time, Elapsed Time, Paused,
  and Active Pace (min/km).
- [ ] Verify the split table title says "Split Active Pace (min/km)" and its
  Selected, Comparison, and delta columns remain readable.
- [ ] Verify the active-pace-over-distance comparison chart appears with
  workout names in the legend.
- [x] Verify chart axes show Distance (km) and min/km.
- [x] Verify chart subtitle says "lower is faster".
- [x] Verify 2D route overlay appears.
- [x] Verify primary/comparison legend appears.
- [x] Verify changing the primary selection clears comparison safely.
- [x] Import a local TCX through the visible Import control.
- [x] Compare the imported TCX with a bundled run and verify warnings appear for
  very different distances or route shapes.
- [x] Verify warnings show common distance when routes differ significantly.
- [ ] Verify the single-run map still toggles correctly after comparison.
- [x] Verify export actions are still exposed.
- [x] Save at least one JSON, CSV, and PNG export in a normal desktop session.

## Apple Maps 2D/3D Toggle Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs.

Checklist:

- [x] App launches without crash.
- [x] Open the single-run map and confirm only one map surface exists per view.
- [x] Use the in-map toggle to switch from top-down 2D to pitched 3D.
- [x] Confirm streets, labels, route, and annotations remain
  on the same map while toggling.
- [ ] Confirm pan, rotate, zoom, compass, scale, and zoom controls work.
- [ ] Confirm Fit Route reframes the route in both modes.
- [ ] Start replay and confirm the current-position marker moves in both modes.
- [x] Open Compare with both bundled runs and toggle that same map between 2D
  and 3D.
- [x] Confirm primary remains blue and comparison remains orange.
- [ ] Confirm comparison warnings remain visible when applicable.

Implementation checks:

- [x] The shipped surface is SwiftUI `Map`, not `SceneView`.
- [x] The shared map uses `MapStyle.Elevation.realistic`.
- [x] 2D uses a 0° camera pitch and 3D uses a pitched `MapCamera`.
- [x] One in-map 2D/3D button controls the shared `MapCameraPosition`.
- [x] Single-run and comparison maps reuse `RouteMapCanvas`.
- [x] The discarded snapshot-on-SceneKit-plane code is removed.

## Comparison Selected-Distance Dogfood Checklist

- [ ] Open Compare with primary and comparison workouts selected.
- [x] Verify distance slider appears at the bottom of the comparison map.
- [x] Verify distance readout shows "0.00 km / X.XX km" format.
- [x] Move the slider and verify both P and C markers appear on the routes.
- [x] Verify markers move along the routes as the slider is scrubbed.
- [ ] Verify elapsed time, active time, and active pace readouts update for both
  routes.
- [x] Test at a midpoint distance.
- [ ] Verify the slider is disabled when routes are empty.
- [x] Toggle pitch while the slider is active and confirm markers remain on the
  same routes.
- [ ] Confirm backward-end and forward-end buttons still work.

Comparison dogfood record (2026-07-08):

- The bundled demo pair loaded on launch and produced summary deltas, split
  deltas, a pace chart, a 2D route overlay, and a legend.
- The comparison picker excluded the current primary workout.
- A local TCX imported successfully and produced a third run in the sidebar.
- Comparing the shorter TCX against a bundled run showed different-distance and
  different-route warnings and did not crash.
- Export menu actions were present, and save-panel export of JSON, CSV, and PNG
  confirmed working in manual GUI pass on 2026-07-08.

## Comparison Chart Readability Checklist

- [x] Comparison chart legend uses actual workout names (not "Primary"/"Comparison").
- [x] Chart y-axis shows min/km units.
- [x] Chart x-axis shows Distance (km).
- [x] Chart subtitle says "lower is faster".
- [ ] Split comparison table title shows Active Pace and min/km units without
  truncation.
- [x] Proper empty states when comparison data is unavailable.
- [x] Warnings appear for different distances, insufficient overlap, missing data.

Comparison chart readability record (2026-07-08):

- This record predates the pause-aware labels in the current branch. The
  unchanged chart layout was verified then; the reset items above require a
  fresh GUI pass.
- Legend displays actual workout names.
- Axes and table headers show clear min/km units.
- Empty states and warnings display correctly.

## Export Smoke Checklist

Use bundled synthetic data for committed artifacts.

- [x] JSON summary export generated by `ExportServiceTests`.
- [x] Splits CSV export generated by `ExportServiceTests`.
- [x] Segments CSV export generated by `ExportServiceTests`.
- [x] Combined CSV export generated by `ExportServiceTests`.
- [x] PNG summary export generated by `ExportServiceTests`.
- [x] Synthetic demo PNG written to `docs/assets/demo-summary.png`.
- [x] Demo PNG opened and visually inspected.
- [x] Demo export text checked for private-data markers in tests.
- [x] Save-panel export of JSON, CSV, and PNG in a normal desktop session.

## Default View Checklist

- [x] On launch with sample data, user sees a map (Overview tab) as the default view
- [x] Map shows the route polyline with start/finish annotations
- [x] Summary metrics bar is visible below the map
- [x] Replay controls are accessible from the Overview tab
- [x] Native MapKit pitch toggle switches the Overview map between 2D and 3D
- [x] Charts tab still works when selected
- [x] Overview and Charts are the only detail tabs; no duplicate Map tab is shown

Default-view dogfood record:

- On 2026-07-08, a human owner verified the prior map, summary, replay, and
  Charts flow in a normal desktop session.
- On 2026-07-11, the bundled sample was launched from the SwiftPM app bundle:
  Overview and Charts were the only detail tabs, and the Overview map toggled
  between native 2D and 3D presentations.

## Replay Visual Smoke Checklist

Automated coverage: `ReplayControllerTests` exercises `advancePlayback(by:)`,
end-of-route landing, speed multipliers, and marker-mapping fallback logic.
The following items still require manual GUI verification.

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the bundled sample run.

Checklist:

- [x] **Overview tab playback**: press Play, yellow 2D marker advances along the route on the map.
- [x] **Pitch toggle during playback**: toggle the Overview map between 2D and 3D while
  playing; the same marker continues advancing on the same route.
- [x] **Current metrics panel**: during playback, the metrics panel (distance, pace, HR) updates at each tick.
- [x] **Charts tab**: switch to Charts tab, press Play, the current-distance indicator follows playback.
- [ ] **Step forward**: press step-forward button, marker advances one route point.
- [ ] **Step backward**: press step-backward button, marker moves back one route point.
- [ ] **Slider seek**: drag the chart distance slider, marker jumps to the seeked position.
- [ ] **End-of-route**: let playback run to completion; marker lands on the final route point and playback pauses.
- [ ] **Restart from end**: after playback reaches the end, press Play again; playback restarts from the beginning.
- [ ] **Speed change**: set speed to 4x, press Play, verify playback is visibly faster.
- [ ] **Pause stops animation**: press Play then Pause; marker stops advancing immediately.

## Delete UI Checklist

- [x] Right-click on a workout row shows "Delete Run" context menu
- [x] Selecting "Delete Run" shows a confirmation dialog
- [x] Confirming deletion removes the workout from the sidebar
- [x] Deleting the selected workout selects the next available
- [x] Deleting the comparison workout clears comparison mode
- [x] Deleting the last workout shows empty state
- [x] Keyboard delete (backspace) on selected workout works

Latest delete UI notes (2026-07-08):

- All items verified by human owner in a normal desktop session.
- Context menu, confirmation dialog, and deletion all work correctly.
- Comparison mode clears when the comparison workout is deleted.
- Empty state appears when the last workout is deleted.

## Legacy SceneKit Controls

The former SceneKit-only pace/elevation/heart-rate coloring buttons are not part
of the unified MapKit surface. Do not describe them as current product controls.

Latest export notes:

- Test-level export smoke coverage uses `RunPlayStudio/Resources/sample_run.json`
  and generated segments from that synthetic workout.
- The committed demo PNG is generated from bundled synthetic data only.
- Manual GUI pass on 2026-07-08 confirmed save-panel export works for JSON,
  CSV, and PNG in a normal desktop session.


## Route replay video export (synthetic)

Use **synthetic or bundled demo workouts only**. Do not commit generated MP4s.

1. Open Export → **Export Route Replay (MP4)** on a synthetic workout with GPS.
2. Confirm poster preview, duration presets (15/30/60), Light/Dark, and route colour.
3. Export a 15-second MP4; open in QuickTime: 1920×1080, no audio, marker reaches finish, progress 100%.
4. Cancel a longer export mid-encode; confirm no partial destination file remains.
5. Confirm live replay position is unchanged after export.
6. Confirm unavailable metric route colours cannot silently produce a differently labelled video.
7. Trigger a recoverable encode/save failure; choose **Try Again…** and retry.
8. Keyboard-navigate the sheet and inspect the poster/status accessibility summaries.
9. Confirm exactly one completion, failure, or cancellation announcement per outcome.

Automated coverage: `WorkoutVideoFramePlanTests`,
`WorkoutVideoReplaySamplerTests`, `WorkoutVideoMapPreparerTests`,
`WorkoutVideoFrameRendererTests`, `WorkoutVideoExporterTests`, and
`WorkoutVideoExportViewModelTests`.

## Comparison replay video export (synthetic)

Use **synthetic or bundled demo workouts only**. Do not commit generated MP4s.

1. Open Compare with two synthetic GPS workouts; confirm **Export Comparison Replay (MP4)…** is enabled.
2. Distance mode: export 15 seconds; QuickTime should show P and C markers, common-distance progress end, dual clocks.
3. Route-Aware mode (when available): export 15 seconds; confirm matched clocks, separation, quality line, block label if multi-block.
4. When Route-Aware is unavailable, confirm Distance remains available and no silent fallback labels Distance as Route-Aware.
5. Cancel a longer export; confirm no destination/temp file and live comparison slider/mode unchanged.
6. Keyboard-navigate the sheet; poster exposes one combined accessibility summary.

Automated coverage: `ComparisonVideoFramePlanTests`, `ComparisonVideoSamplerTests`,
`ComparisonVideoAlignmentResolverTests`, `ComparisonVideoPixelMapTests`,
`ComparisonVideoExporterTests`, `ComparisonVideoExportViewModelTests`.

Offline export record (2026-08-10): steps 2–5 were exercised through the
production `ComparisonVideoExporter` — real `MapKitComparisonVideoMapPreparer`,
`.production` policy — driven from an out-of-tree harness against two generated
winding synthetic routes (~5.7 km, 35 m apart, 300 vs 278 s/km). The app's own
workout library was never opened. Both a Distance/Light and a Route-Aware/Dark
15-second export produced, per `ffprobe`, one H.264 High stream, 1920×1080,
30 fps, 450 frames, 15.000000 seconds, BT.709 primaries/transfer/matrix, and no
audio stream; a string scan found no coordinates, UUIDs, or filesystem paths in
the container. Decoded start/middle/final frames showed both routes in their
distinct colours, both P and C markers, per-side panels, and a progress bar
reaching 100% with both markers at the finish. The Route-Aware frames carried
the `Matched Elapsed`/`Matched Active`/`Matched Pace` labels, per-side distances
that legitimately differ, `Quality Good`, and a separation of 36 m against the
constructed 35 m offset. Cancelling a 60-second encode mid-flight left neither
the destination nor a `runplay-video-*` temporary. Route-Aware over deliberately
disjoint routes failed closed with `unsupportedGeographicExtent` and wrote no
file, so Distance was never silently relabelled. QuickTime opened both files and
reported 1920×1080 at 15.0 s.

That pass found one defect, now fixed with a regression test: the pace delta
rendered as `C faster by 0:19 /km slower`, because the pace branch of
`formatDelta` let `formatSignedDurationDelta` append its default trailing label.
The text was both self-contradictory and clipped at the delta panel edge.

Packaged-app record (2026-08-10): the remaining steps were then run against an
unsigned `scripts/package-demo.sh` build launched with an isolated `HOME` and
`CFFIXED_USER_HOME`, so it seeded the two bundled synthetic demo runs and never
opened the developer's own library. **Export Comparison Replay (MP4)…** was
enabled in the Compare header. The sheet opened with the pair fixed, inherited
the live Route-Aware mode and its snapshot (`Excellent · 7.6 km matched ·
93%/93% coverage · 4 m median separation`), and rendered a midpoint poster.
Switching 30 → 15 sec re-rendered the poster without re-fetching the basemap.
The native save panel pre-filled
`morning-park-run-vs-morning-park-progression-run-comparison-replay.mp4`; the
export completed with a single completion alert, and `ffprobe` reported one
H.264 High stream, 1920×1080, 30 fps, 450 frames, 15.000000 s, BT.709, and no
audio. During encoding every configuration control was disabled and the primary
button became **Cancel Export**; cancelling a 60-second export left neither the
chosen destination nor any `runplay-video-*` temporary. After both a completed
and a cancelled export the live Compare state was untouched — still Route-Aware,
slider still at 0.00 / 7.62 km. The pace delta rendered as `P faster by
5:35 /km`, confirming the fix above in the shipping UI.

Not covered: Tab-order keyboard navigation (macOS keyboard navigation is off by
default on the test machine and was deliberately not changed), a spoken
VoiceOver pass, and Route-Aware-unavailable behaviour in the GUI — the last is
covered by the offline record above, which showed it failing closed with
`unsupportedGeographicExtent` and writing no file. Escape does not dismiss the
sheet, but the pre-existing Summary Card sheet behaves identically, so that is
app-wide rather than specific to this feature.

Focused pre-merge smoke record (2026-08-03): an ad-hoc packaged build was
launched with a fresh temporary `HOME` and `CFFIXED_USER_HOME`, using only the
bundled demo workouts. The toolbar command opened the native sheet; all three
duration segments rendered without clipping and exposed their full 15/30/60
second names through the accessibility tree. All three duration options were
selected. Light/Dark appearance and Solid/Pace route-colour changes refreshed
the poster and its accessibility summary. A 15-second Light/Solid export
completed through the native save panel and produced one completion alert. It
played to its final frame in QuickTime with the finish marker, 100% progress,
and source time 35:42/35:42. `ffprobe` reported one H.264 video stream, 1920×1080,
30 fps, 450 frames, 15.000000 seconds, BT.709 colour metadata, and no audio
stream. The live replay remained at 0:00. Escape during a 60-second encode
settled on the Cancelled state, re-enabled the controls, and left neither the
chosen destination nor a matching temporary artifact under `/private/tmp`.

The accessibility tree was inspected for the configuration, poster, save,
progress, completion, and cancellation states. A spoken VoiceOver pass and a
manually forced encoder failure were not performed. Unavailable-colour
normalization, retry behavior, and single terminal-announcement behavior are
covered deterministically by the focused tests above.

## Map-aware PNG summary export (synthetic)

Use **synthetic or bundled demo workouts only**. Do not commit private PNGs.

1. Open Export → **Export Summary Card (PNG)** and confirm the configuration sheet.
2. Generate Light and Dark **map-inclusive Solid** cards; reopen the PNG and confirm
   exact **1200×1600** pixels and start/finish markers (no replay marker).
3. Generate Pace, Heart Rate, and Elevation cards when available; compare legends
   with the live single-workout map.
4. Disable Include Map; confirm metrics-only export still works.
5. Use a no-GPS synthetic workout; Include Map should be unavailable/off.
6. Simulate offline/map failure if practical; use **Retry** and **Export Without Map**.
7. Change options rapidly; confirm the preview updates without stale content.
8. Cancel generation; confirm no error alert for cancellation.
9. Keyboard-navigate the sheet; inspect VoiceOver labels on controls and preview.
10. Confirm JSON/CSV export, comparison, and personal heatmap remain unchanged.

Automated coverage: `PNGExportRendererTests`, `PNGSummaryExportTests`,
`PNGSummaryExportViewModelTests`, `MapSnapshotRegionPlannerTests`,
`MapSnapshotOverlayComposerTests`.

Focused pre-merge smoke record (2026-07-22): the packaged app was launched with
an isolated temporary home and only bundled or generated synthetic workouts.
Light and Dark map-inclusive Solid cards, Pace, Heart Rate, Elevation,
metrics-only, and no-GPS cards were saved under `/private/tmp`, reopened, and
confirmed as distinct 1200×1600 PNGs. Start/finish markers appeared without a
replay marker, and Pace, Heart Rate, and Elevation legend values matched the
live map accessibility labels exactly. The no-GPS sheet disabled Include Map,
explained the metrics-only fallback, and exported successfully. Rapid option
changes settled on the latest configuration; Escape cancelled active preview
work without an alert; Return invoked the default Export PNG action; and the
accessibility tree exposed concise labels, help, status, and preview text.

A host-wide network disconnect was not used because there is no safe per-app
MapKit network fault switch. The same offline/map-failure state is exercised
deterministically by `PNGSummaryExportViewModelTests`, including Retry, Export
Without Map, stale-preview rejection, and save retry. Save-panel JSON and
combined CSV exports were reopened and inspected, and comparison and Personal
Heatmap were entered successfully after the PNG flow.

## Strava bulk archive import (synthetic)

Use a **synthetic** ZIP only — never commit real exports.

1. **Import Strava Archive…** → select synthetic ZIP.
2. Confirm review counts and candidate statuses.
3. Filter/search; Select All Importable / Select None; keyboard navigation.
4. Import mixed FIT/GPX/TCX/GZIP running activities.
5. Cancel a second large import; confirm no partial library additions.
6. Archive with one corrupt activity → valid siblings still import.
7. Import the same archive again → zero new workouts.
8. Completion report counts match expectations.
9. Open most recent imported workout; check laps/replay/charts.
10. Open Personal Heatmap → one recomputation with new history.
11. Quit and relaunch → workouts persist.
12. Delete one imported workout → heatmap updates.
13. Single-file import and comparison still work.
14. Light/dark, keyboard, VoiceOver labels on the archive sheet.

Focused pre-merge smoke record (2026-07-19): the packaged app exposed
**Import Strava Archive…** in both the File menu and native Import menu. A
temporary synthetic GPX archive scanned as one ready candidate, imported with
an `Imported: 1` completion report, and opened the resulting workout with its
route and replay. A repeat scan showed `1` duplicate, `0` ready/selected
candidates, and a disabled **Import 0 Runs** action; cancelling that review
returned to the workout cleanly. The imported run appeared in Personal Heatmap
(seven included runs) and remained selected after close/relaunch. The full
warning-clean suite covers cancellation rollback and library deletion. The
synthetic app-library record was then removed through the native delete
confirmation; the original ZIP remained untouched.

## Routes workspace (automatic route grouping)

Synthetic library required (never dogfood private data).

### Prep: synthetic fixture set

The Personal Records fixtures above are too small to show route grouping (progression
needs repeats, containment needs near-miss geometry, and Re-cluster needs enough
workouts to show progress). Generate one Strava-archive-style ZIP and bulk-import it in
a single action instead of importing files one at a time:

```bash
python3 - << 'PY'
import csv, io, math, os, random, sys, zipfile
from datetime import datetime, timedelta, timezone

BASE_LAT, BASE_LON = 37.7749, -122.4194
M_PER_DEG_LAT = 111_320.0
def m_per_deg_lon(lat): return 111_320.0 * math.cos(math.radians(lat))
def to_latlon(base_lat, base_lon, e, n):
    return base_lat + n / M_PER_DEG_LAT, base_lon + e / m_per_deg_lon(base_lat)

def square_loop(side_m, step_m=20.0):
    perimeter, pts, t = side_m * 4, [], 0.0
    while t <= perimeter:
        pos = t % perimeter
        if pos < side_m: e, n = pos, 0.0
        elif pos < 2 * side_m: e, n = side_m, pos - side_m
        elif pos < 3 * side_m: e, n = side_m - (pos - 2 * side_m), side_m
        else: e, n = 0.0, side_m - (pos - 3 * side_m)
        pts.append((e, n, t))
        if t >= perimeter: break
        t = min(perimeter, t + step_m)
    return pts

def with_spur(loop_pts, spur_m, step_m=20.0):
    pts, base_t, along = list(loop_pts), loop_pts[-1][2], 0.0
    while along <= spur_m:
        pts.append((along, 0.0, base_t + along))
        if along >= spur_m: break
        along = min(spur_m, along + step_m)
    return pts

def prefix(loop_pts, fraction):
    cutoff = loop_pts[-1][2] * fraction
    return [p for p in loop_pts if p[2] <= cutoff]

def reverse_route(pts):
    total = pts[-1][2]
    return [(e, n, total - t) for e, n, t in reversed(pts)]

def jitter(pts, noise_m, seed):
    rnd = random.Random(seed)
    return [(e + rnd.uniform(-noise_m, noise_m), n + rnd.uniform(-noise_m, noise_m), t) for e, n, t in pts]

class Activity:
    def __init__(self, id_, name, gpx, date): self.id, self.name, self.gpx, self.date = id_, name, gpx, date

def build_gpx(name, base_lat, base_lon, pts, start_dt, pace_s_per_km):
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<gpx version="1.1" creator="RunPlayFixtureGenerator">',
             f"  <trk><name>{name}</name><trkseg>"]
    for e, n, travelled in pts:
        lat, lon = to_latlon(base_lat, base_lon, e, n)
        elapsed_s = travelled / 1000.0 * pace_s_per_km
        ts = (start_dt + timedelta(seconds=elapsed_s)).strftime("%Y-%m-%dT%H:%M:%SZ")
        alt = 15.0 + 3.0 * math.sin(travelled / 400.0)
        lines.append(f'    <trkpt lat="{lat:.7f}" lon="{lon:.7f}"><ele>{alt:.1f}</ele><time>{ts}</time></trkpt>')
    lines += ["  </trkseg></trk>", "</gpx>"]
    return "\n".join(lines)

out_dir = "/tmp/runplay-routes-fixtures"
os.makedirs(out_dir, exist_ok=True)
activities, next_id = [], [1000]
def add(name, lat, lon, pts, start_dt, pace):
    activities.append(Activity(next_id[0], name, build_gpx(name, lat, lon, pts, start_dt, pace), start_dt))
    next_id[0] += 1

# Family A: 5.2 km loop, 8 repeats, 2 reversed, improving pace over ~7 months.
a_lat, a_lon, a_side = BASE_LAT, BASE_LON, 1300.0
a_clean = square_loop(a_side, step_m=25.0)
a_dates = [datetime(2026, 2, 15, 7, 30, tzinfo=timezone.utc), datetime(2026, 3, 8, 7, 30, tzinfo=timezone.utc),
           datetime(2026, 4, 2, 7, 30, tzinfo=timezone.utc), datetime(2026, 4, 27, 7, 30, tzinfo=timezone.utc),
           datetime(2026, 5, 30, 7, 30, tzinfo=timezone.utc), datetime(2026, 6, 25, 7, 30, tzinfo=timezone.utc),
           datetime(2026, 7, 28, 7, 30, tzinfo=timezone.utc), datetime(2026, 8, 22, 7, 30, tzinfo=timezone.utc)]
a_paces = [320, 310, 305, 295, 300, 285, 275, 265]
for i, (d, pace) in enumerate(zip(a_dates, a_paces)):
    pts = jitter(a_clean, 9.0, 1000 + i)
    reversed_ = i in (2, 5)
    if reversed_: pts = reverse_route(pts)
    add(f"Loop A Run {i + 1}" + (" (Reversed)" if reversed_ else ""), a_lat, a_lon, pts, d, pace)

# Family B: 1.2 km loop, 4 repeats, different location.
b_lat, b_lon, b_side = BASE_LAT + 0.035, BASE_LON + 0.035, 300.0
b_clean = square_loop(b_side, step_m=20.0)
b_dates = [datetime(2026, 7, 1, 6, 45, tzinfo=timezone.utc), datetime(2026, 7, 14, 6, 45, tzinfo=timezone.utc),
           datetime(2026, 7, 29, 6, 45, tzinfo=timezone.utc), datetime(2026, 8, 12, 6, 45, tzinfo=timezone.utc)]
for i, (d, pace) in enumerate(zip(b_dates, [295, 292, 288, 290])):
    add(f"Loop B Run {i + 1}", b_lat, b_lon, jitter(b_clean, 6.0, 2000 + i), d, pace)

# Containment: loop+spur and a 5-in-6 prefix of Family A's loop — each must
# land as its own route (mutual coverage below 0.90 rejects both).
add("Loop A Run + Spur", a_lat, a_lon, jitter(with_spur(a_clean, 1000.0, 25.0), 9.0, 3001),
    datetime(2026, 5, 5, 7, 30, tzinfo=timezone.utc), 300)
add("Loop A Run (Cut Short)", a_lat, a_lon, jitter(prefix(a_clean, 5.0 / 6.0), 9.0, 3002),
    datetime(2026, 6, 3, 7, 30, tzinfo=timezone.utc), 300)

# Singletons: 3 spatially separate one-off runs.
for i, (lat, lon, dist, d) in enumerate([
    (BASE_LAT + 0.12, BASE_LON - 0.10, 4200.0, datetime(2026, 3, 20, 8, 0, tzinfo=timezone.utc)),
    (BASE_LAT - 0.15, BASE_LON + 0.08, 6800.0, datetime(2026, 6, 10, 8, 0, tzinfo=timezone.utc)),
    (BASE_LAT + 0.20, BASE_LON + 0.20, 3400.0, datetime(2026, 8, 1, 8, 0, tzinfo=timezone.utc)),
]):
    add(f"Singleton Run {i + 1}", lat, lon, jitter(square_loop(dist / 4.0, 25.0), 8.0, 4000 + i), d, 300)

# Filler: enough scattered runs that a full Re-cluster is observable and
# cancellable. Bump filler_count for a bigger library (training load,
# watch-folder, etc. can reuse this generator wholesale).
rnd, filler_count = random.Random(99), 300
filler_start = datetime(2026, 1, 5, 6, 0, tzinfo=timezone.utc)
for i in range(filler_count):
    lat, lon = BASE_LAT + rnd.uniform(-0.6, 0.6), BASE_LON + rnd.uniform(-0.6, 0.6)
    dist = rnd.uniform(600.0, 2200.0)
    pts = jitter(square_loop(dist / 4.0, step_m=40.0), 10.0, 5000 + i)
    d = filler_start + timedelta(days=rnd.uniform(0, 260), minutes=rnd.uniform(0, 600))
    add(f"Filler Run {i + 1:03d}", lat, lon, pts, d, rnd.uniform(270, 340))

csv_buf = io.StringIO()
writer = csv.writer(csv_buf)
writer.writerow(["Activity ID", "Activity Name", "Activity Type", "Activity Date", "Filename"])
for a in activities:
    writer.writerow([a.id, a.name, "Run", a.date.strftime("%Y-%m-%dT%H:%M:%SZ"), f"activities/{a.id}.gpx"])
zip_path = os.path.join(out_dir, "routes_fixtures.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("export/activities.csv", csv_buf.getvalue())
    for a in activities:
        zf.writestr(f"export/activities/{a.id}.gpx", a.gpx)
print(f"Wrote {zip_path}: {len(activities)} activities")
PY

BIN=$(swift build -c release --show-bin-path)
./scripts/assemble-app-bundle.sh --output /tmp/dev/RunPlayStudio.app \
  --bundle-identifier dev.local.runplay.routes --skip-build --bin-dir "$BIN"
RUNPLAY_LIBRARY_ROOT=/tmp/runplay-routes-check open \
  --env RUNPLAY_LIBRARY_ROOT=/tmp/runplay-routes-check -a /tmp/dev/RunPlayStudio.app
```

Import via **File → Import Strava Archive…**, select
`/tmp/runplay-routes-fixtures/routes_fixtures.zip`, **Select All Importable**, then
**Import N Runs**. This produces: an 8-run 5.2 km loop family (2 reversed, improving
pace, spread across ~7 months) for the progression chart and reversed-member marking; a
4-run 1.2 km loop family at a different location for the route list and filter menus; a
loop-plus-1 km-spur and a 5-in-6 prefix of the main loop — each must land as its own
route, since mutual coverage (≈0.84 and ≈0.83) sits below the 0.90 grouping threshold —
making the containment decision visible; three spatially separate singleton runs; and
300 scattered filler runs so a full Re-cluster takes long enough to observe progress and
press Cancel. Geometry mirrors `RouteGroupingFixtures.swift` so fixtures exercise the
same matcher paths the unit tests do.

Reusable wholesale for other features needing a library-sized synthetic set (training
load, watch-folder): adjust the family/filler parameters and re-run.

- [x] Import the same synthetic loop three times with different GPS jitter:
      Routes (⌘⇧G) shows one route with 3 runs and best/median/latest active
      pace.
- [x] Import the loop reversed: it joins the same route and the run list
      marks it "Reversed".
- [x] Import the loop plus an extra spur: it stays a separate route (mutual
      coverage decides — a run that covers a route plus extra distance is
      not the same route; Merge is the manual recovery path).
- [x] Import a loop sharing only part of the path with another: the two
      routes stay separate.
- [ ] The representative route map draws the representative run's polyline
      with start/finish annotations; 2D/3D and Fit Route work.
- [ ] The pace-over-date chart renders for groups with ≥ 2 paced runs, and
      VoiceOver reads the chart via its descriptor and spoken summary.
- [ ] Rename a route (context menu and detail toolbar): the custom name
      sticks; clearing the name returns the derived "X km Loop/Route"
      default.
- [x] Merge two routes: members move and the target keeps its name.
- [ ] Remove a run from a route: it disappears from the route, stays in All
      Runs, and is not re-added by later imports (only Re-cluster restores).
- [x] Pin a representative: the map overlay switches to that run.
- [ ] Re-cluster Routes shows progress, cancels cleanly leaving the previous
      routes intact, and carries over names/pins on success.
- [x] All Runs filter menu: Route → specific route / Not on a Route filters
      the table; the filter survives into a saved smart collection.
- [x] Colliding derived names: two routes whose derived base name collides
      ("1.6 km Loop") read differently in All Runs → Filters → Route and in
      the Personal Heatmap route picker; the compass token and digest suffix
      ("1.6 km Loop (NE·1d4)") is shown in full at the menu's natural width,
      at 1200×800 and at the 720×552 minimum, in light and dark; selecting
      either entry filters to that route's own runs; and VoiceOver speaks the
      full name including the suffix.
- [x] Route menu secondary line: every route in All Runs → Filters → Route
      and in the Personal Heatmap route picker shows its run count and month
      span under the name ("1 run · Jul 2026"); the selected route carries
      the menu's own checkmark; selecting an entry still filters to that
      route. (Light appearance at 1200×800; see the 2026-09-23 record for
      what was not covered.)
- [ ] Personal Heatmap route filter restricts cells to the selected route
      and resets with the other filters.
- [ ] Deleting a member run repairs the route (representative refreshes;
      empty route disappears).
- [x] A fresh import shows up on its route shortly after the import
      completes (asynchronous assignment), without blocking the import UI.
- [x] Relaunch mid-route: session restores the Routes destination (v5).

### Pass record 2026-09-20 (release configuration, synthetic 317-run library)

The feature merged (#122 and the stack below it) before this pass finished, so
this record is a post-merge verification, not a pre-merge gate.

Verified on a release-configuration bundle against a throwaway library built by
the generator above, light and dark appearance, at both a normal window size and
720×500:

- Grouping: the 8-run 5.2 km family grouped as one route with best/median/latest
  active pace and a pace-over-date chart; both reversed members carried the
  "Reversed" marker; the loop-plus-spur and the 5-in-6 prefix each stayed their
  own route (named "Route", not "Loop", because their endpoints do not meet).
- Manual controls: rename via the detail toolbar stuck; merge moved members and
  kept one name (286 → 285 routes); pin switched the representative map overlay;
  remove dropped the member and a later full re-cluster restored it, as the
  checklist states it should.
- Re-cluster: determinate progress (0/317 → 297/317), Cancel left the previous
  routes untouched.
- Filters: All Runs → Route → a named route and "Not on a Route" both filtered
  correctly (1 of 317, and 21 of 317 — the fillers below the 20-point
  participation minimum), and the route filter survived into a saved smart
  collection across navigation.
- Empty and loading states: a library with no repeats shows "No routes yet" with
  the header distinguishing "0 routes · 2 runs awaiting analysis"; the heatmap
  shows "Building heatmap…" while recomputing.
- Session v5: relaunch restored the Routes destination, and (after the fix in
  this PR) the Personal Heatmap route filter.

Accessibility was inspected through the accessibility tree and the view source,
not through a spoken VoiceOver session: the progression chart carries
`accessibilityLabel`/`accessibilityValue` plus an `AXChartDescriptor` with titled
date and pace axes; route rows read as one element (name, run count, best active
pace); member rows read name, date, pace, "representative", "run in the opposite
direction" — reversal is conveyed in words, not by the badge colour alone; and no
announcement is posted from the Routes view, its view model, or AppState, so a
re-cluster cannot announce per workout (progress is a labelled progress element).

Not ticked, and why:

- Representative map 2D/3D and Fit Route: the polyline, start/finish annotations
  and both controls are present, but the controls were not exercised.
- Chart via VoiceOver: the descriptor is verified in the tree and in source; no
  spoken pass was run.
- Rename: only the detail-toolbar path was exercised; the context-menu path and
  clearing a name back to the derived default were not.
- Remove from a route: "not re-added by later imports" was not exercised — no
  import was performed after a removal.
- Re-cluster carry-over: names survived a completed re-cluster; pin carry-over
  was not isolated.
- Heatmap route filter reset alongside the other filters was not exercised.
- Deleting a member run (representative refresh, empty route disappears) was not
  exercised.

### Pass record 2026-09-22 (release configuration, synthetic 317-run library, collision-aware names)

Driven through Computer Use (System Events plus `screencapture`) against a
release bundle of the collision-aware naming branch, on the 317-run library the
generator above produces (286 routes), imported through File → Import Strava
Archive… → Import 317 Runs. Screenshots stayed in `/tmp`; what follows is
transcribed from them.

- All Runs → Filters → Route listed fifteen routes, every one suffixed (the
  fixture's square loops all extend north-east of their start, so each collided
  family resolves at the digest tier): the three formerly identical pairs from
  #134 now read "1.6 km Loop (NE·1d4)" / "1.6 km Loop (NE·4e4)", "1.7 km Loop
  (NE·299)" / "(NE·a63)", "1.2 km Loop (NE·158)" / "(NE·4eb)". Every entry was
  165 pt wide with no ellipsis at the menu's natural width. Selecting the first
  1.6 km entry filtered to 1 of 317 runs, Filler Run 249; the second to Filler
  Run 137 — each the single member the persisted manifest records for that
  group id.
- Personal Heatmap route picker: the same names, full width, in the same style;
  selecting "1.0 km Loop (NE·b5a)" then "1.0 km Loop (NE·aed)" switched the
  picker label, the included count (1 run, 974 m then 1.0 km) and the map to
  each group's own loop.
- Both surfaces re-checked at the 720×552 minimum and at 1200×800, in light and
  in dark appearance: menu entries identical and untruncated in all eight
  combinations.
- VoiceOver (caption panel, arrow-key navigation of the open menus): the Route
  submenu was announced as "Route, submenu, 17 items Any Route", then "2.1 km
  Loop (NE·47d)", "2.0 km Loop (NE·45e)"; the heatmap picker's entries as "2.1
  km Loop (NE·47d)", "2.0 km Loop (NE·45e)"; the picker button itself as "1.0
  km Loop (NE·b5a), Route filter, menu button". The suffix is part of the spoken
  name on both surfaces.

Found and handled:

- On the first import of a session the heatmap picker offered "Any Route"
  alone while the All Runs filter already listed fifteen routes; a relaunch
  populated it. The post-import assignment pass never handed its result to the
  heatmap view model — fixed in the same branch (AppState
  `applyRouteGroupPassResult`, with a Studio test) and re-verified: on the
  fixed build the picker listed fifteen suffixed routes straight from the
  import report's Open Personal Heatmap button, no relaunch.
- At 720×552 the heatmap filter bar wraps its "Date range" / "Resolution" /
  "Minimum repeats" labels even with "Any Route" selected, and with a suffixed
  route selected the labels wrap one letter per line while Fit Heatmap
  collapses to its icon. The menu itself is unaffected. Pre-existing layout
  behaviour that longer names make worse; filed as #160 rather than folded
  into the naming change.

Not ticked, and why: the seven items listed under the 2026-09-20 record were not
re-exercised in this pass, which covered naming only.

### Pass record 2026-09-23 (release configuration, synthetic 317-run library, menu secondary line)

Driven with System Events plus `screencapture` against a release bundle of the
secondary-line branch, on a fresh library holding the generator's 317 runs (286
routes), imported through File → Import Strava Archive… → Import 317 Runs.

- All Runs → Filters → Route: every one of the fifteen routes showed a second,
  smaller line under its name, for example "1.3 km Loop (NE·8c2)" over "1 run ·
  Jul 2026". Selecting it filtered the table to 1 of 317 runs; reopening the
  menu showed the macOS checkmark on that entry alone.
- Personal Heatmap route picker: the same two-line entries; selecting "1.0 km
  Loop (NE·a92)" set the picker title to that name and the checkmark followed.
- Found and fixed during the pass: the first build kept the old `HStack` label,
  and macOS menus flattened it to the name alone (no second line). Without the
  `HStack` the subtitle appeared, but the hand-drawn checkmark `Image` was then
  dropped. The rows are now `Toggle`s, whose checkmark the menu draws itself.

Not covered: the fifteen-entry window contained only single-run routes, so a
multi-month span ("5 runs · Mar – Aug 2026") was checked only by unit tests
(`RouteGroupMenuDetailTests`). Dark appearance, the 720×552 minimum and
VoiceOver were not exercised in this pass.
