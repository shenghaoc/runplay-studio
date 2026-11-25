# Design

Bookmarks resolve with `.withSecurityScope, .withoutUI, .withoutMounting`. `WatchFolderConfiguration` gains an additive `lastKnownPath`. On activation the resolved path is compared with it: a moved folder is followed, its path is recorded, a display name that still matched the old folder name follows the new one, and the bookmark is refreshed. Settings shows the path.
