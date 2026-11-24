# Design

Adding a folder sets `baselinePending` on its persisted state. The first scan records the files already present as `baseline` keys (size, modification time, file name; the folder path is left out so a moved folder keeps its baseline) and imports none. Later passes skip baselined files. `importExistingNow` drops the baseline so those files import once. A baselined file that changes gets a new key and imports as new.
