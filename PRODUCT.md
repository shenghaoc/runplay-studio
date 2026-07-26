# Product

## Register

product

## Users

Runners who want to analyze GPS workout data locally on their Mac. They care about precision metrics (pace, elevation, heart rate, splits), route visualization, and comparing runs against each other. They value privacy and don't want their data leaving their machine.

Context: post-run analysis at a desk, not mid-activity. The user has just finished a run and wants to dig into the data — or is planning tomorrow's effort by reviewing past performance.

## Product Purpose

RunPlay Studio is a local-first desktop replay and analysis studio for GPS running workouts. Import completed runs from GPX, TCX, FIT, or JSON files, from a multi-session FIT container, or from a local Strava bulk-export ZIP and explore them with synchronized 2D/3D maps, charts, split analysis, and route comparison. Export summaries as JSON, CSV, or configurable PNG summary cards (optional static Apple Maps region, Light/Dark appearance, and metric route coloring) at a fixed 1200×1600 pixel size.

Success means: a runner opens the app, imports a workout, and within seconds sees their route on a map with meaningful metrics — no accounts, no cloud, no friction.

## Desktop continuity

RunPlay Studio is a single-workspace macOS app rather than a document editor.
It presents one native main window backed by one app-owned coordinator, while
macOS restores the window frame and the app restores its logical workspace in
a separate, versioned session file. A relaunch can return to a workout tab,
manual All Runs query, active smart collection, Personal Heatmap filters,
comparison pair and alignment mode, paused replay position, and sidebar visibility.

The workout-library manifest remains the authority for library membership,
order, selected workout, favourites, tags, assignments, and smart collections.
Session restoration is best-effort and validated against the freshly loaded
library; deleted references fall back safely. Sheets, alerts, active playback,
map/cache data, query results, table selections, and in-progress operations are
transient and never reopened.

## Brand Personality

**Clean, energetic, focused.**

- **Clean**: Layouts that breathe. Information organized, not crammed. The tool disappears so the data speaks.
- **Energetic**: Vibrant but purposeful color. Blue for primary/action, orange for comparison, green for positive deltas. Color signals meaning, not decoration.
- **Focused**: Every feature earns its place. No social feeds, no gamification, no upsells. Deep analysis on few features rather than shallow coverage of many.

## Anti-references

**Do not look like Strava or Garmin.** Specifically avoid:

- Social/community features, follower counts, kudos, leaderboards
- Gamification mechanics (badges, challenges, streaks)
- Overly busy dashboards with dozens of competing metrics
- Dark/black-heavy color schemes (Strava's orange-on-black aesthetic)
- Corporate fitness-app tropes: motivational copy, "you vs. you" language, workout selfies

RunPlay Studio is a precision instrument, not a social network. The vibe is "professional tool for people who take their data seriously" — closer to a DAW or a code editor than a fitness app.

## Design Principles

1. **Local-first privacy by design.** No accounts, no cloud backend, no telemetry, no AI APIs. The app processes everything on-device. This isn't a feature flag — it shapes every decision: no login screen, no sync settings, no "share to web" buttons.

2. **Data clarity over decoration.** Metrics use monospaced digits, semantic color, and consistent typography. Charts are interactive but uncluttered. Every pixel of chrome is questioned: does it help the user understand their run?

3. **Energetic precision.** Color signals meaning: blue = primary/action, orange = comparison, green = improvement, red = heart rate/effort. Colors are vibrant but never gratuitous. Motion is purposeful (map transitions, chart scrubbing), never decorative.

4. **Focused depth, not shallow breadth.** Deep replay, rich comparison, relative route metric coloring on the native map, personal route heatmap across the local library, a scalable All Runs browser (search, filter, sort, favourites, tags, smart collections, name/notes), and precise segment detection. No feature-creep: if it doesn't help a runner understand their workout better, it doesn't ship.

5. **Native-first, not cross-platform lowest-common-denominator.** The app feels like a macOS app — native navigation, system fonts, platform conventions, Apple Maps integration. No Electron-style generic UI.

## Accessibility & Inclusion

- WCAG 2.1 AA equivalent where applicable on macOS (sufficient color contrast, keyboard navigation, VoiceOver compatibility). See [docs/accessibility-audit.md](docs/accessibility-audit.md) for the authoritative shortcut matrix and audit boundary.
- Semantic color usage ensures metrics remain distinguishable for common forms of color blindness (blue/orange/green/red are on distinct hue axes)
- Reduced motion support via system `Reduce Motion` accessibility setting
- Dynamic Type support for system font scaling
