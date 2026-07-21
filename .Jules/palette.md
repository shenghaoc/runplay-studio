## 2026-07-21 - Add accessibility labels to Map Fit Route buttons
**Learning:** Icon-only interactive elements using `Label` and `.help()` for tooltips are not accessible to VoiceOver. VoiceOver requires an explicit `.accessibilityLabel()` when the visual representation (like an icon) doesn't natively convey the semantic meaning to screen readers.
**Action:** Always add an explicit `.accessibilityLabel()` alongside `.help()` for icon-only buttons or buttons using symbolic labels.
