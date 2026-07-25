# Tasks: Native Window and Application Session Restoration

- [x] Add versioned AppSessionSnapshot models, bounded store, validator, and
      focused unit tests.
- [x] Move AppState and AppSessionController ownership to the application and
      replace the independent WindowGroup with one native stable-ID window.
- [x] Add startup sequencing, restoration overlay, scene-phase pause/flush, and
      explicit sidebar visibility binding.
- [x] Persist and restore workout tab, map presentation, replay state, manual
      query, smart-collection working state, heatmap filters, and comparison.
- [x] Add bounded save triggers after committed durable mutations without
      persisting transient UI or playback timers.
- [x] Add startup/workspace/replay/query/heatmap/comparison/native-window tests
      and update architecture, data model, privacy, manual testing, README,
      product/design, phase plan, and Kiro steering documentation.
- [x] Run warning-clean SwiftPM and packaged-app verification, publish the
      first coherent implementation commit, open the requested draft PR, and
      refresh exact-head CI/status without merging.

Checked boxes track intended delivery scope; tests and CI prove completion.
