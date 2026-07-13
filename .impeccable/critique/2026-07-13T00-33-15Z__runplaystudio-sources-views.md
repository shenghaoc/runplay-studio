---
target: RunPlayStudio/Sources/Views
total_score: 26
p0_count: 0
p1_count: 2
timestamp: 2026-07-13T00-33-15Z
slug: runplaystudio-sources-views
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | No loading indicator during import processing |
| 2 | Match System / Real World | 4 | Runner terminology, natural order, solid icon metaphors |
| 3 | User Control and Freedom | 2 | No undo for import, no way to abort mid-export |
| 4 | Consistency and Standards | 4 | Design tokens used everywhere, platform-native feel |
| 5 | Error Prevention | 2 | No duplicate import warning, no autosave |
| 6 | Recognition Rather Than Recall | 3 | Toolbar labels + icons good; no search/filter in sidebar |
| 7 | Flexibility and Efficiency | 2 | Space bar only; no keyboard shortcuts for step, tabs, export |
| 8 | Aesthetic and Minimalist Design | 3 | Clean, map-centric; bottom panels can stack densely |
| 9 | Error Recovery | 2 | Error alerts exist but generic — no diagnostic or fix suggestion |
| 10 | Help and Documentation | 1 | No in-app help, no tooltips on most elements, no guided tour |
| **Total** | | **26/40** | **Acceptable** |

## Anti-Patterns Verdict

**LLM assessment:** This does NOT look AI-generated. Semantic color is genuinely purposeful. The map-centric layout is a deliberate choice. Platform-native conventions feel authentic. No gradient text, no glassmorphism, no side-stripe borders, no hero-metric templates, no eyebrow text, no numbered section markers.

**Deterministic scan:** No HTML/CSS findings — expected for a native SwiftUI app.

## Overall Impression

Solid, tasteful start. The semantic color system is the strongest asset. The map-centric layout honors the "Cartographer's Desk" north star. The weakest link is discoverability: once past the empty state, there's no guidance. A first-timer stares at a map with no cues. A power user hits space bar and reaches for shortcuts that don't exist.

## What's Working

1. **Semantic color system** — Every color has a specific data role. Blue=primary route, orange=comparison, green=elevation, red=HR.
2. **Map-centric composition** — The map dominates; metrics orbit around it without competing.
3. **Platform-native integrity** — NavigationSplitView, system fonts, SF Symbols, native alerts. Feels like a macOS app.

## Priority Issues

### [P1] No keyboard shortcuts beyond space bar
DAWs and code editors are keyboard-driven. Only space bar works. No left/right for step, no Tab for tab switching, no Cmd+E for export. Power users feel hamstrung.

### [P1] Error messages are generic
Import errors show raw localizedDescription. No diagnostic info. User doesn't know if file is corrupt, unsupported, or wrong format.

### [P2] Only 2 tabs — Splits and Segments buried below fold
Splits and Segments are first-class features but hidden in bottom panels. On 800pt windows they require scrolling.

### [P2] Missing empty/edge states
No duplicate import detection, no GPS-less workout banner, no FIT limitation warnings in UI.

### [P3] No in-app help or documentation
Empty state handles step 0 well, but steps 1-N have zero guidance. Tooltips exist on replay controls but nowhere else.

## Persona Red Flags

**Alex (Power User):** No keyboard shortcuts for step, tabs, or export. Timeline scrub is mouse-only. Space bar only shortcut. Would feel hamstrung in 5 minutes.

**Jordan (First-Timer):** Empty state is excellent. After import, zero guidance — what are Overview vs Charts? What are segments? Why is Compare grayed out?

**Sam (Accessibility):** Semantic color good for color blindness. Fixed-width layouts (500pt comparison map) will clip at large Dynamic Type sizes. Minimal VoiceOver labels beyond replay buttons.

## Minor Observations

- Export toolbar icon lacks text label (inconsistent with Compare)
- Speed control "Speed" label is tertiary and easily missed
- Comparison winner emoji (✅❌) inconsistent with SF Symbols elsewhere
- currentSplitIndex highlight (subtle orange dot) easy to miss on long tables

## Questions to Consider

- "What would this feel like if it were fully keyboard-driven?"
- "What if the bottom panels were collapsible sections the user could reorder?"
- "What if the first-run experience included a 3-step interactive tour?"
