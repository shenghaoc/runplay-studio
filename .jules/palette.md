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
**Action:** Always provide inline, contextual Calls to Action (CTAs) within empty states that directly solve the condition causing the empty state. This includes the comparison picker's empty slot and the main empty-state view. Ensure buttons use `.help()` and `.accessibilityLabel()` modifiers for VoiceOver support.

## 2026-07-20 - Contextual Empty State CTAs
**Learning:** Empty states without clear next steps cause friction. Relying on global menus or sidebars for primary actions (like importing data) forces users to hunt for functionality.
**Action:** Always provide inline, contextual Calls to Action (CTAs) within empty states (e.g., an "Import File" button when no data is available) that directly solve the condition causing the empty state.

## 2026-07-21 - SwiftUI Label Provides Built-in Accessibility
**Learning:** SwiftUI `Label("Title", systemImage:)` automatically exposes its title text as the accessibility label for VoiceOver, even when used with icon-only label styles. Adding an explicit `.accessibilityLabel()` with the same text is redundant. Only pure `Image(systemName:)` views used directly as button content (without a `Label` wrapper) require an explicit `.accessibilityLabel()`.
**Action:** Do not add `.accessibilityLabel()` to `Label`-based buttons when the label title already conveys the intended meaning. Reserve explicit accessibility labels for buttons that use bare `Image(systemName:)` or other non-text content.

## 2026-07-26 - Empty State Accessibility
**Learning:** Buttons in overlays and empty states—including text actions such as "Import", "All Time", and "Reset Filters"—are standalone CTAs that may be encountered without their surrounding visual context. Although `Button("Label")` supplies a default accessibility label, tooltips are not automatically derived and the visible label alone may not explain what the action will do.
**Action:** Add contextual `.help()` and `.accessibilityLabel()` text to buttons in overlays and empty states so tooltips and VoiceOver communicate the actionable context that sighted users infer from the surrounding explanation.

## 2026-07-31 - Disable Empty Name Form Submission
**Learning:** Create/Save buttons for required tag and smart-collection names stayed enabled when the field was empty or whitespace-only. Click and `.keyboardShortcut(.defaultAction)` could still fire, reaching Core empty-name validation with a poor UX. Sharing one draft between Create and inline Edit made Return submit Create with the edit text (often a duplicate) instead of saving the row.
**Action:** Pair every required-name Create/Save with `.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)` on the same control that owns `.defaultAction` (see `SaveSmartCollectionSheet`). Keep create and edit drafts separate so canceling or saving an edit cannot pollute Create, and disable Create (and its default action) while a row is being edited.

## 2026-08-03 - Recovery CTAs Need Shared Help and Label Parity
**Learning:** The Compare view's route-aware alignment recovery path had two nearly identical "Use Distance Alignment" buttons (`.unavailable` and `.failed`). One gained `.accessibilityLabel()` while the other was left bare, and neither had a `.help()` tooltip. Recovery banners are encountered without the surrounding mode-picker context, so text-only buttons still need explicit tooltip help; duplicating the control also lets accessibility drift between states.
**Action:** Extract recovery CTAs that appear in multiple load/error states into a single shared control (or shared modifiers) so every path gets the same `.help()` and `.accessibilityLabel()`. Prefer a contextual `.help()` that explains the fallback effect, even when the visible title already supplies the accessibility label.
