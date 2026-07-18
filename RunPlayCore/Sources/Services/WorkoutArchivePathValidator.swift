import Foundation

/// Result of validating and normalizing an archive-relative path.
public enum WorkoutArchivePathValidation: Equatable, Sendable {
    case valid(normalized: String)
    case rejected(reason: String)
}

/// Strict path validation for untrusted ZIP entry names.
///
/// Even when entry data is only consumed in memory, paths are used for
/// metadata matching and diagnostics and must never be trusted raw.
public enum WorkoutArchivePathValidator {

    /// Validate and normalize an archive entry path.
    ///
    /// - Parameters:
    ///   - path: Raw path as reported by the archive.
    ///   - maxLength: Maximum allowed path length.
    /// - Returns: Normalized forward-slash path without leading `./`, or rejection.
    public static func validate(
        _ path: String,
        maxLength: Int = WorkoutArchiveSecurityPolicy.default.maxPathLength
    ) -> WorkoutArchivePathValidation {
        if path.isEmpty {
            return .rejected(reason: "Empty path")
        }
        if path.count > maxLength {
            return .rejected(reason: "Path exceeds maximum length")
        }
        if path.contains("\0") {
            return .rejected(reason: "Path contains NUL character")
        }
        // Reject absolute POSIX and Windows paths.
        if path.hasPrefix("/") || path.hasPrefix("\\") {
            return .rejected(reason: "Absolute path")
        }
        if path.contains(":") {
            // Windows drive (`C:`) or alternate data stream style paths.
            let beforeColon = path.prefix(while: { $0 != ":" })
            if beforeColon.count == 1, beforeColon.first?.isLetter == true {
                return .rejected(reason: "Windows drive path")
            }
            // Also reject other colon forms for safety.
            return .rejected(reason: "Path contains colon")
        }

        let unified = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if unified.isEmpty {
            return .rejected(reason: "Empty path after normalization")
        }

        var components: [String] = []
        for raw in unified.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(raw)
            if part == "." {
                continue
            }
            if part == ".." {
                return .rejected(reason: "Path traversal")
            }
            if part.isEmpty {
                return .rejected(reason: "Malformed path separators")
            }
            components.append(part)
        }

        if components.isEmpty {
            return .rejected(reason: "Empty path after normalization")
        }

        let normalized = components.joined(separator: "/")
        if normalized.count > maxLength {
            return .rejected(reason: "Path exceeds maximum length")
        }
        return .valid(normalized: normalized)
    }

    /// Whether an entry should be ignored (macOS junk, photos, etc.).
    public static func shouldIgnore(_ normalizedPath: String) -> Bool {
        let lower = normalizedPath.lowercased()
        let filename = (normalizedPath as NSString).lastPathComponent.lowercased()

        if filename == ".ds_store" { return true }
        if filename.hasPrefix("._") { return true }
        if lower.hasPrefix("__macosx/") || lower.contains("/__macosx/") { return true }
        if lower.hasPrefix("photos/") || lower.contains("/photos/") { return true }
        if lower.hasPrefix("media/") || lower.contains("/media/") { return true }
        if lower.hasPrefix("profile/") || lower.contains("/profile/") { return true }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".png") || lower.hasSuffix(".gif")
            || lower.hasSuffix(".heic") || lower.hasSuffix(".mp4")
            || lower.hasSuffix(".mov") {
            return true
        }
        return false
    }

    /// Match a metadata filename to an archive entry path.
    ///
    /// Policy: (1) exact normalized path; (2) unique case-insensitive fallback;
    /// (3) ambiguous matches rejected.
    public static func matchPath(
        _ target: String,
        in entries: [String]
    ) -> PathMatchResult {
        matchPath(target, index: PathIndex(entries: entries))
    }

    /// Match using a precomputed index (O(1) lookups for bulk candidate building).
    public static func matchPath(
        _ target: String,
        index: PathIndex
    ) -> PathMatchResult {
        let validation = validate(target)
        guard case .valid(let normalizedTarget) = validation else {
            return .none
        }

        if index.exact.contains(normalizedTarget) {
            return .exact(normalizedTarget)
        }

        // Suffix: activities/foo.gpx vs export/activities/foo.gpx
        let targetLast = (normalizedTarget as NSString).lastPathComponent
        if let paths = index.bySuffix[normalizedTarget], paths.count == 1, let only = paths.first {
            return .exact(only)
        }
        if let paths = index.byLastComponent[targetLast], paths.count == 1, let only = paths.first {
            return .exact(only)
        }
        // Ambiguous exact basenames fall through to case-insensitive resolution.

        let lowerTarget = normalizedTarget.lowercased()
        if let paths = index.byLowercased[lowerTarget] {
            if paths.count == 1, let only = paths.first {
                return .caseInsensitive(only)
            }
            if paths.count > 1 {
                return .ambiguous
            }
        }

        let lowerLast = targetLast.lowercased()
        if let paths = index.byLowercasedLastComponent[lowerLast] {
            if paths.count == 1, let only = paths.first {
                return .caseInsensitive(only)
            }
            if paths.count > 1 {
                return .ambiguous
            }
        }

        return .none
    }

    public enum PathMatchResult: Equatable, Sendable {
        case exact(String)
        case caseInsensitive(String)
        case ambiguous
        case none
    }

    /// Precomputed lookup tables for O(1) path matching across many metadata rows.
    public struct PathIndex: Sendable {
        public let exact: Set<String>
        public let byLowercased: [String: [String]]
        public let byLastComponent: [String: [String]]
        public let byLowercasedLastComponent: [String: [String]]
        /// Paths keyed by every suffix path component chain (`a/b/c`, `b/c`, `c`).
        public let bySuffix: [String: [String]]

        public init(entries: [String]) {
            var exact = Set<String>()
            var byLowercased: [String: [String]] = [:]
            var byLastComponent: [String: [String]] = [:]
            var byLowercasedLastComponent: [String: [String]] = [:]
            var bySuffix: [String: [String]] = [:]

            exact.reserveCapacity(entries.count)
            for path in entries {
                exact.insert(path)
                byLowercased[path.lowercased(), default: []].append(path)
                let last = (path as NSString).lastPathComponent
                byLastComponent[last, default: []].append(path)
                byLowercasedLastComponent[last.lowercased(), default: []].append(path)

                // Register all suffix forms so `activities/1.gpx` matches `export/activities/1.gpx`.
                let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if !parts.isEmpty {
                    for start in parts.indices {
                        let suffix = parts[start...].joined(separator: "/")
                        bySuffix[suffix, default: []].append(path)
                    }
                }
            }

            self.exact = exact
            self.byLowercased = byLowercased
            self.byLastComponent = byLastComponent
            self.byLowercasedLastComponent = byLowercasedLastComponent
            self.bySuffix = bySuffix
        }
    }
}
