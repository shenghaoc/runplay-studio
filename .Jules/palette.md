## 2024-05-17 - Button Ambiguity in SwiftUI
**Learning:** Even text buttons like "Clear" can be ambiguous to screen readers or lack tooltip affordances when they exist far from their controlled context (e.g., in a complex comparison view selector).
**Action:** Always add `.help()` and `.accessibilityLabel()` to buttons that might be ambiguous, perform destructive/clearing actions, or could benefit from explicit context for VoiceOver and mouse users.
