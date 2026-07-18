## 2024-05-15 - Interactive Icon Buttons Need Accessibility Descriptors
**Learning:** In SwiftUI, icon-only interactive elements like Buttons using `Image(systemName:)` don't automatically provide context to VoiceOver or mouse hover users. This creates an accessibility barrier for playback controls and other pure-icon UI components.
**Action:** Always add `.help("Description")` and `.accessibilityLabel("Description")` to buttons that only display icons to ensure they are discoverable and usable by everyone.
## 2024-05-18 - Missing Accessibility Labels on Icon-only Buttons
**Learning:** Found instances of icon-only interactive elements lacking specific voiceover descriptions. While they had `.help()` tooltips, they missed `.accessibilityLabel()`, leaving screen reader users without proper context for the map distance slider jump buttons.
**Action:** Always ensure both `.help()` and `.accessibilityLabel()` modifiers are present for icon-only components in this SwiftUI project to guarantee full accessibility support.

## 2026-07-12 - Interactive Custom Views Lack Keyboard Focus on macOS
**Learning:** Using `.onTapGesture` on custom views (like cards or rows) in SwiftUI on macOS handles mouse clicks but fails to make the element keyboard focusable or actionable via Space/Return. This breaks keyboard navigation entirely for those elements.
**Action:** For interactive custom views on macOS, wrap the view in a `Button` and apply `.buttonStyle(.plain)` instead of using `.onTapGesture`. This preserves the design while providing free Tab focus, keyboard activation, and better VoiceOver integration.

## 2026-07-13 - Button Ambiguity in SwiftUI
**Learning:** Even text buttons like "Clear" can be ambiguous to screen readers or lack tooltip affordances when they exist far from their controlled context (e.g., in a complex comparison view selector).
**Action:** Always add `.help()` and `.accessibilityLabel()` to buttons that might be ambiguous, perform destructive/clearing actions, or could benefit from explicit context for VoiceOver and mouse users. Make `.help()` more descriptive and contextual than `.accessibilityLabel()` to avoid redundant screen reader announcements.

## 2026-07-15 - Empty States Require Actionable CTAs
**Learning:** The comparison empty state informed users they needed another run to compare, but lacked a direct way to resolve this (no import button), forcing them to hunt for the global import action in the sidebar or toolbar.
**Action:** Always provide inline, contextual Calls to Action (CTAs) within empty states that directly solve the condition causing the empty state.
## 2024-05-14 - Inline CTAs in Empty States
**Learning:** Empty states in comparison workflows (like waiting for a second workout to be selected) can be dead-ends if they only provide instructional text ("Import another run") when the requisite data isn't available. Users are forced to find the global import action to proceed.
**Action:** Always provide inline, contextual Calls to Action (CTAs) within empty states (e.g., an 'Import File' button when no data is available) that directly solve the condition causing the empty state, rather than forcing users to find global actions. Ensure the button uses `.help()` and `.accessibilityLabel()` modifiers for VoiceOver support.
