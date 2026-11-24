# Design

`DefaultTagDraft` stages the edit; the field commits on Return or loss of focus through `WatchFolderConfiguration.normalizedTagName` (control characters dropped, trimmed, blank means no tag), and Escape discards it. The Recent Imports popover takes focus when it opens so its Escape handler also works after a pointer open.
