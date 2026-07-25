# Requirements: Keyboard Navigation and VoiceOver Accessibility Audit

## Problem

RunPlay Studio is a native macOS workout analysis app. After window and session
restoration (PR #66), the remaining polish gap is full keyboard access, a
coherent command architecture, VoiceOver support for charts and maps, and
system accessibility settings (Reduce Motion, Differentiate Without Colour,
Increased Contrast). Users must complete major workflows with keyboard only,
VoiceOver, or both.

## Requirements

1. The application SHALL expose an authoritative command registry that lists
   every discoverable menu command with menu title, key equivalent, workspace,
   purpose, and accessibility description. Help → Keyboard Shortcuts SHALL be
   generated from or checked against that registry without a second hard-coded
   matrix that can drift.
2. Command routing SHALL use SwiftUI `Commands` and focused action bundles
   (`ReplayActions`, `LibraryActions`, `MapActions`, workspace actions). Menu
   availability SHALL follow the focused workspace. Sheets SHALL not inherit
   destructive background shortcuts. A narrow NotificationCenter fallback MAY
   remain only for workspace navigation when scene focus is cleared.
3. Existing navigation shortcuts SHALL be preserved: Command-1…4 workout tabs,
   Command-Shift-L All Runs, Command-Shift-H Personal Heatmap, Command-I import
   file, Command-Shift-I Strava archive, Command-F focus All Runs search when
   All Runs is active.
4. Replay SHALL provide menu/keyboard commands for play/pause (Space), seek
   ±5 s (Option-Left/Right), slower/faster (`[` / `]`), and restart
   (Command-Shift-Left). Space SHALL not trigger replay while typing in text
   fields. Bare Left/Right frame steps SHALL remain local to focused replay
   controls so tables, lists, sliders, and text keep native arrow behaviour.
5. Map fit and 2D/3D toggle SHALL be discoverable commands routed only to the
   visible map. MapKit-owned zoom shortcuts SHALL not be re-bound.
6. All Runs SHALL support Command-F search focus, Escape clear when search owns
   focus and is nonempty, Return open for exactly one selection, Delete for one
   eligible persisted workout, and menu access to tag editing, filters, and sort.
7. Charts SHALL expose Swift Charts accessibility descriptors and a concise
   spoken summary (min/max/average orientation, current value, gaps). Drag-to-seek
   SHALL have keyboard and accessibility-action equivalents.
8. Maps, comparison, and Personal Heatmap SHALL expose nonvisual summaries of
   analytical meaning without per-point or per-cell VoiceOver explosion. Colour
   alone SHALL NOT convey comparison identity, metric mode, or mixed tag state.
9. VoiceOver announcements SHALL occur only for deliberate user actions and
   phase transitions. Replay 30 fps ticks and continuous progress SHALL never
   announce.
10. Reduce Motion SHALL suppress non-essential camera and decorative animation
    while leaving replay content functional. Differentiate Without Colour SHALL
    add textual markers where colour identity matters. Increased Contrast and
    Reduce Transparency SHALL preserve readable controls using system materials
    and design tokens.
11. Focused automated tests SHALL cover the command registry, focused actions,
    replay keyboard semantics, accessibility summaries, chart models, and
    announcement policy. Packaged-app keyboard and VoiceOver verification SHALL
    be documented honestly in `docs/accessibility-audit.md`.

## Non-goals

- Custom shortcut editing, global inactive hotkeys, speech recognition, TTS
  narration of workouts, reverse geocoding, per-route-point or per-heatmap-cell
  VoiceOver trees, video export, HealthKit, cloud services, telemetry, AI.
