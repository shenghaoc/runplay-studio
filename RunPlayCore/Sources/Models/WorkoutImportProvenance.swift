import Foundation

/// Identifies how a workout entered the local library.
public enum WorkoutImportProvider: String, Codable, Hashable, Sendable, CaseIterable {
    /// Single-file import via the standard file picker.
    case singleFile
    /// Activity extracted from a Strava bulk-export ZIP.
    case stravaBulkExport
    /// One session extracted from a multi-session FIT container.
    ///
    /// Ordinary one-session FIT files keep `.singleFile`; this case exists so
    /// duplicate detection can compare session identities rather than the
    /// container hash that every sibling necessarily shares.
    case fitMultiSessionFile
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
    ///
    /// Semantics are unchanged for Strava and ordinary activity-file imports.
    /// Multi-session FIT leaves this `nil`: every sibling session shares one
    /// container, so a whole-file hash here would make them look identical.
    public var contentSHA256: String?
    /// Archive-relative or original filename of the activity entry (not a full path).
    public var originalFilename: String?
    /// Lowercase hex SHA-256 of the complete original container that produced
    /// this workout, when the workout is one of several extracted from it.
    ///
    /// Backward compatible: snapshots written before this field decode as `nil`
    /// and need no manifest, analysis, normalization, or source-structure
    /// version bump.
    public var sourceContainerSHA256: String?

    public init(
        provider: WorkoutImportProvider = .unknown,
        providerActivityID: String? = nil,
        contentSHA256: String? = nil,
        originalFilename: String? = nil,
        sourceContainerSHA256: String? = nil
    ) {
        self.provider = provider
        self.providerActivityID = providerActivityID
        self.contentSHA256 = contentSHA256
        self.originalFilename = originalFilename
        self.sourceContainerSHA256 = sourceContainerSHA256
    }
}
