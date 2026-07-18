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
        let validation = validate(target)
        guard case .valid(let normalizedTarget) = validation else {
            return .none
        }

        if entries.contains(normalizedTarget) {
            return .exact(normalizedTarget)
        }

        // Also try matching by suffix (activities/foo.gpx vs export/activities/foo.gpx)
        let targetLast = (normalizedTarget as NSString).lastPathComponent
        let exactSuffixMatches = entries.filter {
            $0 == normalizedTarget
                || $0.hasSuffix("/" + normalizedTarget)
                || ($0 as NSString).lastPathComponent == targetLast
                    && entries.filter { ($0 as NSString).lastPathComponent == targetLast }.count == 1
        }
        if exactSuffixMatches.count == 1, let only = exactSuffixMatches.first {
            return .exact(only)
        }

        let lowerTarget = normalizedTarget.lowercased()
        let caseMatches = entries.filter { $0.lowercased() == lowerTarget }
        if caseMatches.count == 1, let only = caseMatches.first {
            return .caseInsensitive(only)
        }
        if caseMatches.count > 1 {
            return .ambiguous
        }

        let lowerLast = targetLast.lowercased()
        let caseLastMatches = entries.filter {
            ($0 as NSString).lastPathComponent.lowercased() == lowerLast
        }
        if caseLastMatches.count == 1, let only = caseLastMatches.first {
            return .caseInsensitive(only)
        }
        if caseLastMatches.count > 1 {
            return .ambiguous
        }

        return .none
    }

    public enum PathMatchResult: Equatable, Sendable {
        case exact(String)
        case caseInsensitive(String)
        case ambiguous
        case none
    }
}
