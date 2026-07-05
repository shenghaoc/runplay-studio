# Prompt: Improve Segment Detection

## Context

RunPlay Studio detects basic segments (fastest/slowest km, steepest climb/descent). This needs improvement.

## Task

Enhance segment detection in `RunPlayStudio/Sources/Services/SegmentDetector.swift`:

1. **More segment types**:
   - Fastest 400m (for track runners)
   - Fastest mile
   - Longest climb
   - Fastest 5-minute window
   - Negative split (second half faster than first)

2. **Better accuracy** - Use interpolation for exact segment boundaries

3. **Confidence scoring** - Rate segment detection confidence

4. **Visualization** - Highlight detected segments on:
   - 3D route (colored overlay)
   - Charts (shaded regions)
   - Map (colored polyline)

5. **Segment list** - Show all detected segments in a sidebar panel

## Files to Modify

- `RunPlayStudio/Sources/Services/SegmentDetector.swift`
- `RunPlayStudio/Sources/Views/SegmentHighlightsView.swift` (create)
- `RunPlayStudio/Sources/Views/Route3DReplayView.swift`

## Acceptance Criteria

- [ ] Detects multiple segment types
- [ ] Segments shown on 3D route
- [ ] Segments shown on charts
- [ ] Segment list view works
- [ ] Detection is accurate with test data
