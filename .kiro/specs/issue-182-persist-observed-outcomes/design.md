# Design

`WatchFolderState` gains an additive `observedOutcomes` list. A duplicate copy is keyed by content hash plus file name; an oversized file by its fingerprint (size, modification time and path), because it is never hashed. The coordinator seeds its skip set from the oversized entries and checks the duplicate entries before it reports.
