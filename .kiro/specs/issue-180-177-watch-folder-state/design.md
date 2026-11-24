# Watch-folder state design

The version-one store gains an optional-on-read master pause field. Older
files default to false without reinterpreting folder flags. The coordinator
uses effective pause to manage watcher handles and to gate work after async
scans. A started import is not interrupted; the next import reads the latest
configuration from the coordinator. Settings and Recent Imports use the same
effective state. Historical scanning behavior is unchanged when watching is active.
