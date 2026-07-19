import Foundation

/// Identifies how a workout entered the local library.
public enum WorkoutImportProvider: String, Codable, Hashable, Sendable, CaseIterable {
    /// Single-file import via the standard file picker.
    case singleFile
    /// Activity extracted from a Strava bulk-export ZIP.
    case stravaBulkExport
    /// Provenance is unknown or missing (legacy snapshots).
    case unknown
}

/// Optional, backward-compatible import provenance stored on a workout snapshot.
///
/// Old snapshots decode with `nil` provenance. No analysis, normalization, or
/// manifest schema version bump is required.
///
/// Privacy: never store absolute archive paths, account emails, or profile IDs.
public struct WorkoutImportProvenance: Codable, Hashable, Sendable {
    public var provider: WorkoutImportProvider
    /// Provider-native activity identifier when available (e.g. Strava activity ID).
    public var providerActivityID: String?
    /// Lowercase hex SHA-256 of the original activity-file bytes before parsing.
    public var contentSHA256: String?
    /// Archive-relative or original filename of the activity entry (not a full path).
    public var originalFilename: String?

    public init(
        provider: WorkoutImportProvider = .unknown,
        providerActivityID: String? = nil,
        contentSHA256: String? = nil,
        originalFilename: String? = nil
    ) {
        self.provider = provider
        self.providerActivityID = providerActivityID
        self.contentSHA256 = contentSHA256
        self.originalFilename = originalFilename
    }
}
