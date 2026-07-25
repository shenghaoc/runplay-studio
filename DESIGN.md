---
name: RunPlay Studio
description: A native macOS post-run 2D/3D route replay and analysis app for runners.
colors:
  primary-blue: "#0A84FF"
  comparison-orange: "#FF9F0A"
  energetic-green: "#30D158"
  alert-red: "#FF453A"
  soft-purple: "#BF5AF2"
  warm-yellow: "#FFD60A"
  duration-ice: "#64D2FF"
  pace-sky: "#409CFF"
typography:
  hero:
    fontFamily: "SF Pro Rounded, system-ui"
    fontSize: "largeTitle"
    fontWeight: 700
    design: rounded
  section-headline:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "headline"
    fontWeight: 600
  metric-value:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "callout"
    fontWeight: 600
  metric-label:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "caption"
    fontWeight: 500
  compact-label:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "caption2"
    fontWeight: 500
rounded:
  sm: "6pt"
  md: "8pt"
  lg: "12pt"
  xl: "16pt"
spacing:
  xs: "2pt"
  sm: "4pt"
  compact: "6pt"
  inner: "8pt"
  component: "12pt"
  section: "16pt"
  generous: "20pt"
  major: "24pt"
components:
  button-primary:
    backgroundColor: "{colors.primary-blue}"
    textColor: "#FFFFFF"
    rounded: "{rounded.md}"
  metric-display:
    backgroundColor: "transparent"
    textColor: "inherit"
  card-panel:
    backgroundColor: "NSColor.controlBackgroundColor"
    rounded: "{rounded.md}"
  card-active:
    backgroundColor: "accentColor.opacity(0.08)"
    rounded: "{rounded.md}"
---

# Design System: RunPlay Studio

## 1. Overview

**Creative North Star: "The Cartographer's Desk"**

RunPlay Studio is a precision instrument for runners who take their data seriously — closer to a cartographer's workstation than a fitness app. The interface is clean and analytical: a map dominates the visual field, metrics orbit with semantic purpose, and all chrome exists to serve data comprehension. Every pixel of decoration is questioned.

The system is **flat and tonal** — depth comes from native adaptive surfaces, not decorative shadows. Surfaces breathe through generous spacing and restrained backgrounds. Color is vibrant but never gratuitous: each hue carries a specific semantic role, and no color appears without meaning.

This system explicitly rejects the Strava/Garmin aesthetic: no dark/black-heavy schemes, no social feeds, no gamification badges, no motivational copy. The vibe is "field notebook meets DAW" — a tool that disappears so the data can speak.

**Key Characteristics:**
- Map-centric layout with metrics as supporting context
- Semantic color: every hue maps to a specific data type or action
- Flat tonal depth via opacity-based backgrounds (0.03–0.08)
- System-native typography (SF Pro) — no custom fonts
- Monospaced digits on all metric values for precise comparison
- Vibrant but controlled palette — one small, fixed set of semantic colors

## 2. Colors

The palette is vibrant and semantic — each color carries meaning about the data it represents. No color appears purely for decoration.

### Primary
- **Run Blue** (#0A84FF): The primary brand color. Used for the primary route polyline, key interactive elements, distance metrics, and primary action buttons. This is the system's dominant accent.

### Secondary
- **Comparison Orange** (#FF9F0A): The comparison/secondary accent. Used for comparison route overlays, speed metrics, split indicators, and chart drag indicators. Visually distinct from blue while staying warm and energetic.

### Tertiary
- **Energetic Green** (#30D158): Positive deltas, elevation gain, start markers, success states. Signals improvement and upward movement.
- **Alert Red** (#FF453A): Heart rate metrics, finish markers, negative deltas, destructive actions. High-impact, used sparingly.
- **Soft Purple** (#BF5AF2): Elevation loss, descent segments, cadence. Cooler and calmer than the other accents.
- **Warm Yellow** (#FFD60A): Current position marker, caution states. High visibility; never used as a background.

### Neutral
- **Duration Ice** (#64D2FF): Duration metrics. A lighter, cooler blue distinct from the primary.
- **Pace Sky** (#409CFF): Pace metrics. Sits between primary blue and duration ice on the blue ramp.

### Named Rules
**The Semantic-Only Rule.** Every color in the palette maps to a specific data type or UI role. Never introduce a new color without defining its semantic purpose. Decorative accent colors are prohibited.

**The One-Accent-Per-Screen Rule.** Primary blue dominates. Secondary orange appears only alongside comparisons. Tertiary colors appear only when their semantic data type is present. No rainbow dashboards.

## 3. Typography

**Display Font:** SF Pro Rounded (system, with `.rounded` design modifier)
**Body Font:** SF Pro Text (system, default design)
**Mono Digits:** Applied via `.monospacedDigit()` on all metric values

**Character:** Clean, native, unpretentious. The system font feels at home on macOS without drawing attention to itself. Rounded display weight on hero metrics adds warmth without sacrificing precision. Monospaced digits ensure numbers align for scannable comparison.

### Hierarchy
- **Hero Metric** (.largeTitle, rounded, bold): Large primary values in summary cards and export previews. The only use of the rounded design modifier.
- **Section Headline** (.headline, semibold): Panel titles, section headers. Secondary color.
- **Metric Value** (.callout, semibold, monospaced): Data values in badges, cards, and tables. Colored by semantic metric type.
- **Metric Label** (.caption, medium): Labels beneath metric values. Tertiary color.
- **Compact Metric** (`caption`, medium): Tight-space values in comparison badges and sidebar rows.
- **Compact Label** (`caption2`, medium): The smallest text tier — sidebar metadata, pill labels, chart axis labels.

## 4. Elevation

The system uses **flat tonal layering**. Depth is conveyed through native adaptive backgrounds rather than decorative shadows:

- **Panel Background:** `controlBackgroundColor` — native grouped surface for panels.
- **Card Background:** `underPageBackgroundColor` — subtly separated card surfaces.
- **Active Card Background:** `Color.accentColor.opacity(0.08)` — selected or highlighted cards.
- **Overlay Background:** `Color(nsColor: .controlBackgroundColor).opacity(0.85)` — map control overlays.

All surfaces are flat at rest. No shadow appears on any component. This keeps the interface clean and content-first — the data defines the visual weight, not the chrome.

## 5. Components

### Buttons
- **Primary:** `.borderedProminent` style with Run Blue background. Large control size for CTA (empty state import).
- **Toolbar:** System toolbar buttons with SF Symbols. Icon + label in compact form.
- **Destructive:** System red role for delete actions. Always confirmed with an alert dialog.
- **Shape:** Rounded rect, 8pt radius (system default for `.borderedProminent`).

### Metric Display
The core data atom: label + value + optional icon, colored by semantic metric type. Two layouts:
- **Centered:** Compact badge context (live metrics panel). Vertical stack, icon above value.
- **Leading:** Summary cards and detail rows. Horizontal alignment for table-like layouts.
- Value text always uses `.monospacedDigit()` for precise comparison.
- Labels always use tertiary foreground style.

### Cards / Panels
- **Corner Style:** 8pt radius (medium). Larger hero cards use 12–16pt.
- **Background:** Native `controlBackgroundColor` panels and `underPageBackgroundColor` cards, adapting automatically to system appearance.
- **Border:** Usually none. Compact interactive segment cards use a 1pt low-contrast boundary so they remain recognizable as controls.
- **Internal Padding:** 8–12pt (inner to component scale).

### Navigation
- **Sidebar:** Native `.sidebar` list style with one shared selection for Library destinations and bounded workout rows. Library lists **All Runs** and **Personal Heatmap**. Workout lists use capped **Favourites** and **Recent** sections (plus **Selected Run** when needed), not the full library. Rows use one leading symbol, one title line, and one compact metadata line.
- **All Runs:** Native search field, compact filter/sort controls, and a `Table` of lightweight columns (favourite, date, name, distance, pace, elapsed, source, device). Missing values use an em dash, not fake zeros.
- **Tab Bar:** Horizontal picker for workout detail tabs (Overview, Charts, Splits, Segments).
- **Toolbar:** Primary action buttons (Compare, Export) in the toolbar, not inline.

### Window and session behavior

- **Main window:** A stable-ID SwiftUI `Window` provides one coordinated
  workspace. `RunPlayStudioApp` owns the `AppState` and session controller;
  `ContentView` receives them and never creates production root state.
- **Native frame restoration:** macOS owns close, minimise, zoom, full-screen,
  placement, and frame restoration. A display-aware default near 1200×800 is
  used only for a new window, with a 720×500 minimum content size.
- **Logical session:** A separate versioned JSON snapshot restores destination,
  All Runs/manual-query and smart-collection context, heatmap filters,
  comparison, paused replay, detail presentation, and sidebar visibility.
  Library manifest state remains authoritative for selected workout and library
  organisation.
- **Transient state:** Sheets, alerts, editors, active operations, map/cache
  data, query results, table selections, and active playback are not restored.

### Format Pills
Small badges showing supported import/export formats. Semantic `.caption2` medium typography with panel background fill and 6pt radius. Used in empty state and format hints.

### Empty State
Native workspace background, hero icon in a material circle, and a reduced-motion-aware entrance. Import CTA uses `.borderedProminent` with large control size.

### PNG Summary Export Card
Fixed **1200×1600** canvas for offline sharing. Uses **explicit Light and Dark export
palettes** (never ambient `windowBackgroundColor`). Map-inclusive hierarchy:

1. Branding, title, date, source
2. Static Apple Maps basemap with composited route + start/finish
3. Route-color legend when Pace/HR/Elevation is active
4. Primary metrics
5. Compact key segments (up to 3) and splits (up to 5)
6. Privacy/map note

Metrics-only layout retains up to 5 segments / 10 splits. Typography uses larger
inline system sizes appropriate to the fixed canvas. Route metric hex stops match
the live map palettes.

## 6. Do's and Don'ts

### Do:
- **Do** use Run Blue (#0A84FF) exclusively for the primary route and primary actions — its rarity on screen makes it meaningful.
- **Do** use monospaced digits on all metric values so numbers align for scannable comparison.
- **Do** use semantic metric colors consistently: distance=blue, pace=sky, speed=orange, elevation=green, heart rate=red, cadence=purple.
- **Do** keep single-workout route metric palettes sequential and relative to the workout; never imply personalised HR zones. Comparison remains blue/orange; heatmap density colors stay separate.
- **Do** use native adaptive surfaces and restrained semantic tints for separation — never decorative shadows.
- **Do** keep the map as the dominant visual element. Metrics support the map, not the reverse.
- **Do** resolve export Light/Dark colors explicitly so PNG output is identical regardless of system appearance at render time.
- **Do** prefer native SwiftUI components and SF Symbols over custom-drawn equivalents.
- **Do** use system font scaling (Dynamic Type) so the interface respects the user's accessibility settings.

### Don't:
- **Don't** look like Strava or Garmin — no dark/black-heavy schemes, no social feeds, no gamification badges, no leaderboard aesthetics.
- **Don't** introduce decorative colors. Every color maps to a data type or UI role. No "accent for accent's sake."
- **Don't** use shadows for depth. The system is flat and tonal. Use native adaptive backgrounds instead.
- **Don't** use gradient text (`background-clip: text` equivalent). Solid semantic colors only.
- **Don't** use side-stripe borders greater than 1pt as decorative accents on cards or panels.
- **Don't** add gamification language ("You crushed it!", "New record!", streaks, challenges).
- **Don't** clutter the interface with social features — no sharing buttons, follower counts, kudos, or community feeds.
- **Don't** use custom fonts. SF Pro (system) is the only typeface. Rounded design modifier is reserved for hero metrics only.

## Tags and smart collections

- Tag chips show the **name** with a finite supplemental color token (not RGB freeform).
- All Runs table Tags column shows up to three chips plus `+N`; untagged shows `—`.
- Smart Collections appear as a bounded sidebar section (cap 8) with overflow management.
- Active collection chrome shows Modified, Revert, and Update Collection (never silent save).
