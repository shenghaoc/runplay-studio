import Foundation

/// Platform-neutral data-based import request.
///
/// Prefer this over temporary files when activity bytes already live in memory
/// (e.g. archive entries). URL-based import remains supported and delegates
/// here after local-file validation.
public struct WorkoutImportInput: Sendable {
    public let data: Data
    /// Lowercase file extension without a leading dot (e.g. `"gpx"`, `"fit"`).
    public let fileExtension: String
    public let suggestedName: String
    public let provenance: WorkoutImportProvenance?

    public init(
        data: Data,
        fileExtension: String,
        suggestedName: String,
        provenance: WorkoutImportProvenance? = nil
    ) {
        self.data = data
        self.fileExtension = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.suggestedName = suggestedName
        self.provenance = provenance
    }
}
