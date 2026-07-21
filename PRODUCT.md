# Product

## Register

product

## Users

Runners who want to analyze GPS workout data locally on their Mac. They care about precision metrics (pace, elevation, heart rate, splits), route visualization, and comparing runs against each other. They value privacy and don't want their data leaving their machine.

Context: post-run analysis at a desk, not mid-activity. The user has just finished a run and wants to dig into the data — or is planning tomorrow's effort by reviewing past performance.

## Product Purpose

RunPlay Studio is a local-first desktop replay and analysis studio for GPS running workouts. Import completed runs from GPX, TCX, FIT, or JSON files, or from a local Strava bulk-export ZIP and explore them with synchronized 2D/3D maps, charts, split analysis, and route comparison. Export summaries as JSON, CSV, or polished PNG cards.

Success means: a runner opens the app, imports a workout, and within seconds sees their route on a map with meaningful metrics — no accounts, no cloud, no friction.

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

4. **Focused depth, not shallow breadth.** Deep replay, rich comparison, relative route metric coloring on the native map, personal route heatmap across the local library, and precise segment detection. No feature-creep: if it doesn't help a runner understand their workout better, it doesn't ship.

5. **Native-first, not cross-platform lowest-common-denominator.** The app feels like a macOS app — native navigation, system fonts, platform conventions, Apple Maps integration. No Electron-style generic UI.

## Accessibility & Inclusion

- WCAG 2.1 AA equivalent where applicable on macOS (sufficient color contrast, keyboard navigation, VoiceOver compatibility)
- Semantic color usage ensures metrics remain distinguishable for common forms of color blindness (blue/orange/green/red are on distinct hue axes)
- Reduced motion support via system `Reduce Motion` accessibility setting
- Dynamic Type support for system font scaling
