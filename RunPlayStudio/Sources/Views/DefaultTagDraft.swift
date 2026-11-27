import RunPlayCore

/// A watch folder's default tag while it is being edited (#183).
///
/// Typing changes only `text`. The stored tag changes when the edit is
/// committed (Return, or the field losing focus), and Escape throws the edit
/// away. Kept as a plain value so the rules are unit-tested without a view.
struct DefaultTagDraft: Equatable {
    private(set) var committed: String
    var text: String

    init(committed: String) {
        self.committed = committed
        self.text = committed
    }

    /// The value a commit would store, or nil when it equals the stored tag.
    var pendingCommit: String? {
        let normalized = WatchFolderConfiguration.normalizedTagName(text)
        return normalized == committed ? nil : normalized
    }

    /// Commit the edit. Returns the value to persist, or nil when nothing changed.
    /// The field then shows the normalised value that was stored.
    mutating func commit() -> String? {
        let normalized = WatchFolderConfiguration.normalizedTagName(text)
        text = normalized
        guard normalized != committed else { return nil }
        committed = normalized
        return normalized
    }

    /// Drop the edit and show the stored tag again.
    mutating func discard() {
        text = committed
    }

    /// The stored tag changed elsewhere; an untouched draft follows it.
    mutating func committedExternally(_ value: String) {
        if text == committed { text = value }
        committed = value
    }
}
