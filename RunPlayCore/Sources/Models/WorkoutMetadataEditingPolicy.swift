import Foundation

/// Validation and normalization policy for editable workout name and notes.
public struct WorkoutMetadataEditingPolicy: Hashable, Sendable {
    public static let `default` = WorkoutMetadataEditingPolicy()

    /// Maximum Unicode scalar values for the workout name.
    public let maxNameScalars: Int
    /// Maximum Unicode scalar values for notes.
    public let maxNotesScalars: Int

    public init(maxNameScalars: Int = 200, maxNotesScalars: Int = 5_000) {
        self.maxNameScalars = maxNameScalars
        self.maxNotesScalars = maxNotesScalars
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case nameTooLong(limit: Int)
        case notesTooLong(limit: Int)
        case containsNUL(field: String)

        public var errorDescription: String? {
            switch self {
            case .nameTooLong(let limit):
                return "Name must be at most \(limit) characters."
            case .notesTooLong(let limit):
                return "Notes must be at most \(limit) characters."
            case .containsNUL(let field):
                return "\(field) contains an invalid character."
            }
        }
    }

    public struct NormalizedMetadata: Hashable, Sendable {
        public let name: String?
        public let notes: String?

        public init(name: String?, notes: String?) {
            self.name = name
            self.notes = notes
        }
    }

    /// Validate and normalize editable fields.
    ///
    /// - Trims leading/trailing whitespace (and newlines for name)
    /// - Empty values become `nil`
    /// - Rejects over-limit values (no silent truncation)
    /// - Rejects embedded NUL
    /// - Preserves internal newlines in notes
    public func normalize(name: String?, notes: String?) throws -> NormalizedMetadata {
        let normalizedName = try normalizeOptional(
            name,
            fieldLabel: "Name",
            maxScalars: maxNameScalars,
            preserveInternalNewlines: false
        )
        let normalizedNotes = try normalizeOptional(
            notes,
            fieldLabel: "Notes",
            maxScalars: maxNotesScalars,
            preserveInternalNewlines: true
        )
        return NormalizedMetadata(name: normalizedName, notes: normalizedNotes)
    }

    private func normalizeOptional(
        _ value: String?,
        fieldLabel: String,
        maxScalars: Int,
        preserveInternalNewlines: Bool
    ) throws -> String? {
        guard let value else { return nil }
        if value.unicodeScalars.contains(UnicodeScalar(0)) {
            throw ValidationError.containsNUL(field: fieldLabel)
        }

        let trimmed: String
        if preserveInternalNewlines {
            // Trim only leading/trailing whitespace and newlines; keep internal newlines.
            trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.isEmpty {
            return nil
        }

        let scalarCount = trimmed.unicodeScalars.count
        if scalarCount > maxScalars {
            if fieldLabel == "Name" {
                throw ValidationError.nameTooLong(limit: maxScalars)
            } else {
                throw ValidationError.notesTooLong(limit: maxScalars)
            }
        }
        return trimmed
    }
}
