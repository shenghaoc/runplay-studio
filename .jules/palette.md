## 2024-05-15 - Interactive Icon Buttons Need Accessibility Descriptors
**Learning:** In SwiftUI, icon-only interactive elements like Buttons using `Image(systemName:)` don't automatically provide context to VoiceOver or mouse hover users. This creates an accessibility barrier for playback controls and other pure-icon UI components.
**Action:** Always add `.help("Description")` and `.accessibilityLabel("Description")` to buttons that only display icons to ensure they are discoverable and usable by everyone.
## 2024-05-18 - Missing Accessibility Labels on Icon-only Buttons
**Learning:** Found instances of icon-only interactive elements lacking specific voiceover descriptions. While they had `.help()` tooltips, they missed `.accessibilityLabel()`, leaving screen reader users without proper context for the map distance slider jump buttons.
**Action:** Always ensure both `.help()` and `.accessibilityLabel()` modifiers are present for icon-only components in this SwiftUI project to guarantee full accessibility support.

## 2026-07-12 - Interactive Custom Views Lack Keyboard Focus on macOS
**Learning:** Using `.onTapGesture` on custom views (like cards or rows) in SwiftUI on macOS handles mouse clicks but fails to make the element keyboard focusable or actionable via Space/Return. This breaks keyboard navigation entirely for those elements.
**Action:** For interactive custom views on macOS, wrap the view in a `Button` and apply `.buttonStyle(.plain)` instead of using `.onTapGesture`. This preserves the design while providing free Tab focus, keyboard activation, and better VoiceOver integration.
