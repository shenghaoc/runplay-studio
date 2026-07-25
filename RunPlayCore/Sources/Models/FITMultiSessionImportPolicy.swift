import Foundation

/// Central resource limits for scanning and importing multi-session FIT files.
///
/// Limits that the FIT parser already enforces (container bytes, decoded
/// message count) are re-exported here rather than duplicated with different
/// values, so the two layers can never disagree.
public struct FITMultiSessionImportPolicy: Hashable, Sendable {

    /// Maximum size of the original `.fit` container, in bytes.
    /// Mirrors `FITParser.maxFileSize`; do not raise one without the other.
    public var maxContainerBytes: Int

    /// Maximum session messages considered during a scan.
    public var maxScannedSessions: Int

    /// Maximum sessions the user may import in one transaction.
    public var maxSelectedSessions: Int

    /// Maximum record messages attributed across the container.
    public var maxRecords: Int

    /// Maximum event messages attributed across the container.
    public var maxEvents: Int

    /// Maximum lap messages attributed across the container.
    public var maxLaps: Int

    /// Cooperative cancellation is checked every N processed items.
    public var cancellationCheckStride: Int

    /// Maximum length of a user-visible candidate display name.
    public var maxDisplayNameLength: Int

    /// Maximum length of a generated provider activity identifier.
    public var maxProviderIDLength: Int

    public init(
        maxContainerBytes: Int = 100 * 1024 * 1024,
        maxScannedSessions: Int = 256,
        maxSelectedSessions: Int = 100,
        maxRecords: Int = 1_000_000,
        maxEvents: Int = 200_000,
        maxLaps: Int = 50_000,
        cancellationCheckStride: Int = 1_000,
        maxDisplayNameLength: Int = 120,
        maxProviderIDLength: Int = 128
    ) {
        self.maxContainerBytes = maxContainerBytes
        self.maxScannedSessions = maxScannedSessions
        self.maxSelectedSessions = maxSelectedSessions
        self.maxRecords = maxRecords
        self.maxEvents = maxEvents
        self.maxLaps = maxLaps
        self.cancellationCheckStride = cancellationCheckStride
        self.maxDisplayNameLength = maxDisplayNameLength
        self.maxProviderIDLength = maxProviderIDLength
    }

    public static let `default` = FITMultiSessionImportPolicy()

    /// Truncate a display name on a character boundary, appending an ellipsis
    /// so a truncated name never looks like a complete one.
    public func clampDisplayName(_ name: String) -> String {
        guard name.count > maxDisplayNameLength else { return name }
        guard maxDisplayNameLength > 1 else { return String(name.prefix(maxDisplayNameLength)) }
        return String(name.prefix(maxDisplayNameLength - 1)) + "…"
    }
}
