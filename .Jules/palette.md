## 2024-05-15 - Interactive Icon Buttons Need Accessibility Descriptors
**Learning:** In SwiftUI, icon-only interactive elements like Buttons using `Image(systemName:)` don't automatically provide context to VoiceOver or mouse hover users. This creates an accessibility barrier for playback controls and other pure-icon UI components.
**Action:** Always add `.help("Description")` and `.accessibilityLabel("Description")` to buttons that only display icons to ensure they are discoverable and usable by everyone.
