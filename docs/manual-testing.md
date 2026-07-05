# RunPlay Studio Manual Testing

Manual checks supplement the SwiftPM test suite. Keep results concrete and avoid
committing local workout files or generated exports.

## Route Comparison Dogfood Checklist

Environment:

- Build from the SwiftPM package.
- Launch the app from Xcode or a temporary `.app` bundle built from the package.
- Use the two bundled demo runs and, when available, a local user-provided TCX
  file. Do not commit private workout data.

Checklist:

- [x] App launches with at least two workouts loaded.
- [x] Existing 3D single-run replay renders before entering comparison.
- [x] Open Compare view from the toolbar.
- [x] Select a primary workout.
- [x] Select a comparison workout.
- [x] Verify the current primary workout is not offered as its own comparison.
- [x] Verify summary delta cards appear.
- [x] Verify split comparison appears.
- [x] Verify pace-over-distance comparison chart appears.
- [x] Verify 2D route overlay appears.
- [x] Verify primary/comparison legend appears.
- [x] Verify changing the primary selection clears comparison safely.
- [x] Import a local TCX through the visible Import control.
- [x] Compare the imported TCX with a bundled run and verify warnings appear for
  very different distances or route shapes.
- [x] Verify existing 3D single-run replay still works after comparison.
- [x] Verify export actions are still exposed.
- [ ] Save at least one JSON, CSV, and PNG export in a normal desktop session.

Latest dogfood notes:

- The bundled demo pair loaded on launch and produced summary deltas, split
  deltas, a pace chart, a 2D route overlay, and a legend.
- The comparison picker excluded the current primary workout.
- A local TCX imported successfully and produced a third run in the sidebar.
- Comparing the shorter TCX against a bundled run showed different-distance and
  different-route warnings and did not crash.
- Export menu actions were present, but a save-panel write was intentionally not
  completed in this automated session to avoid browsing outside the repo or
  temporary paths.
