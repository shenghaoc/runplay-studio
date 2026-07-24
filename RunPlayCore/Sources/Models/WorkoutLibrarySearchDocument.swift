import Foundation

/// Precomputed searchable representation for one workout.
///
/// Built once per library / metadata revision so keystrokes do not re-format
/// dates or fold every optional field.
public struct WorkoutLibrarySearchDocument: Hashable, Sendable {
    public let workoutID: UUID
    /// Single folded haystack used for term and phrase matching.
    public let normalizedText: String

    public init(workoutID: UUID, normalizedText: String) {
        self.workoutID = workoutID
        self.normalizedText = normalizedText
    }

    /// Build a document from a lightweight library entry.
    public static func make(
        from entry: WorkoutLibraryEntry,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> WorkoutLibrarySearchDocument {
        var tokens: [String] = []

        tokens.append(entry.displayName)
        if let name = entry.metadataName { tokens.append(name) }
        if let notes = entry.notes { tokens.append(notes) }
        tokens.append(entry.activityType)
        if let device = entry.deviceName { tokens.append(device) }

        // Stable, locale-independent tokens.
        tokens.append(entry.source.rawValue)
        tokens.append(entry.source.displayName)
        if let provider = entry.importProvider {
            tokens.append(provider.rawValue)
            switch provider {
            case .stravaBulkExport:
                tokens.append("Strava")
                tokens.append("strava")
            case .singleFile:
                tokens.append("single")
                tokens.append("file")
            case .unknown:
                break
            }
        }
        if let filename = entry.originalFilename {
            tokens.append(filename)
            // Basename without extension for convenience.
            if let dot = filename.lastIndex(of: ".") {
                tokens.append(String(filename[..<dot]))
            }
        }

        if let date = entry.startDate {
            let comps = calendar.dateComponents(in: calendar.timeZone, from: date)
            if let year = comps.year {
                tokens.append(String(year))
            }
            if let month = comps.month {
                tokens.append(String(format: "%02d", month))
                tokens.append(String(month))
                // English month names as stable search aids (not the only tokens).
                let englishMonths = [
                    "january", "february", "march", "april", "may", "june",
                    "july", "august", "september", "october", "november", "december"
                ]
                if month >= 1, month <= 12 {
                    tokens.append(englishMonths[month - 1])
                }
            }
            if let day = comps.day {
                tokens.append(String(format: "%02d", day))
            }
        }

        // Assigned tag names participate in free-text search (not tag colors).
        for tagName in entry.tagNames {
            tokens.append(tagName)
        }

        // Separate fields with a unit separator so quoted phrases cannot match
        // across independent metadata fields (e.g. name "Marina" + notes "Bay…").
        let joined = tokens
            .map { Self.normalize($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{001F}")

        return WorkoutLibrarySearchDocument(workoutID: entry.id, normalizedText: joined)
    }

    /// Case-, diacritic-, and width-insensitive folding for search.
    public static func normalize(_ string: String) -> String {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\0", with: "")
    }
}

// MARK: - Query parsing

/// Parsed free-text search (AND of terms / phrases).
public struct WorkoutLibrarySearchTerms: Hashable, Sendable {
    /// Each element is a normalized term or quoted phrase (without quotes).
    public let terms: [String]

    public var isEmpty: Bool { terms.isEmpty }

    public static let empty = WorkoutLibrarySearchTerms(terms: [])

    public init(terms: [String]) {
        self.terms = terms
    }

    /// Parse user search text into normalized AND terms.
    ///
    /// - Trims surrounding whitespace
    /// - Splits on whitespace outside quotes
    /// - Preserves quoted phrases
    /// - Empty / whitespace-only → matches everything
    public static func parse(_ raw: String) -> WorkoutLibrarySearchTerms {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var terms: [String] = []
        var current = ""
        var inQuotes = false

        for scalar in trimmed.unicodeScalars {
            let ch = Character(scalar)
            if ch == "\"" {
                if inQuotes {
                    let phrase = WorkoutLibrarySearchDocument.normalize(
                        String(current).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if !phrase.isEmpty {
                        terms.append(phrase)
                    }
                    current = ""
                    inQuotes = false
                } else {
                    let outside = WorkoutLibrarySearchDocument.normalize(
                        String(current).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if !outside.isEmpty {
                        // Unquoted segment may still contain spaces — split later.
                        terms.append(contentsOf: Self.splitUnquoted(outside))
                    }
                    current = ""
                    inQuotes = true
                }
                continue
            }
            current.append(ch)
        }

        let tail = WorkoutLibrarySearchDocument.normalize(
            String(current).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !tail.isEmpty {
            if inQuotes {
                // Unclosed quote: treat remainder as a phrase.
                terms.append(tail)
            } else {
                terms.append(contentsOf: Self.splitUnquoted(tail))
            }
        }

        return WorkoutLibrarySearchTerms(terms: terms.filter { !$0.isEmpty })
    }

    private static func splitUnquoted(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Whether every term appears somewhere in the document haystack.
    public func matches(_ document: WorkoutLibrarySearchDocument) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = document.normalizedText
        return terms.allSatisfy { haystack.contains($0) }
    }
}
