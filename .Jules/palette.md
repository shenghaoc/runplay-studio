## 2024-05-15 - Interactive Icon Buttons Need Accessibility Descriptors
**Learning:** In SwiftUI, icon-only interactive elements like Buttons using `Image(systemName:)` don't automatically provide context to VoiceOver or mouse hover users. This creates an accessibility barrier for playback controls and other pure-icon UI components.
**Action:** Always add `.help("Description")` and `.accessibilityLabel("Description")` to buttons that only display icons to ensure they are discoverable and usable by everyone.
## 2024-05-18 - Missing Accessibility Labels on Icon-only Buttons
**Learning:** Found instances of icon-only interactive elements lacking specific voiceover descriptions. While they had `.help()` tooltips, they missed `.accessibilityLabel()`, leaving screen reader users without proper context for the map distance slider jump buttons.
**Action:** Always ensure both `.help()` and `.accessibilityLabel()` modifiers are present for icon-only components in this SwiftUI project to guarantee full accessibility support.
