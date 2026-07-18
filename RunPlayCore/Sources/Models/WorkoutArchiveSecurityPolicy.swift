import Foundation

/// Centralized finite resource limits for archive scan and batch import.
///
/// Limits are generous enough for a long-running athlete’s full history, but
/// finite so malformed or malicious archives cannot exhaust memory or hang.
public struct WorkoutArchiveSecurityPolicy: Hashable, Sendable {
    public var maxArchiveFileBytes: Int64
    public var maxEntryCount: Int
    public var maxCandidateActivityCount: Int
    public var maxPathLength: Int
    public var maxCompressedEntryBytes: Int64
    public var maxUncompressedEntryBytes: Int64
    public var maxTotalCandidateUncompressedBytes: Int64
    /// Maximum allowed uncompressed/compressed ratio for an entry.
    public var maxCompressionRatio: Double
    public var maxMetadataCSVBytes: Int64
    public var maxCSVFieldBytes: Int
    public var maxCSVRowBytes: Int
    public var maxCSVRows: Int
    /// Bound concurrent activity parse/stage operations.
    public var parsingConcurrency: Int
    /// Check cancellation every N rows/entries/bytes of this stride.
    public var cancellationCheckStride: Int

    public init(
        maxArchiveFileBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxEntryCount: Int = 100_000,
        maxCandidateActivityCount: Int = 50_000,
        maxPathLength: Int = 1_024,
        maxCompressedEntryBytes: Int64 = 50 * 1024 * 1024,
        maxUncompressedEntryBytes: Int64 = 100 * 1024 * 1024,
        maxTotalCandidateUncompressedBytes: Int64 = 5 * 1024 * 1024 * 1024,
        maxCompressionRatio: Double = 100,
        maxMetadataCSVBytes: Int64 = 50 * 1024 * 1024,
        maxCSVFieldBytes: Int = 64 * 1024,
        maxCSVRowBytes: Int = 256 * 1024,
        maxCSVRows: Int = 100_000,
        parsingConcurrency: Int = 2,
        cancellationCheckStride: Int = 64
    ) {
        self.maxArchiveFileBytes = maxArchiveFileBytes
        self.maxEntryCount = maxEntryCount
        self.maxCandidateActivityCount = maxCandidateActivityCount
        self.maxPathLength = maxPathLength
        self.maxCompressedEntryBytes = maxCompressedEntryBytes
        self.maxUncompressedEntryBytes = maxUncompressedEntryBytes
        self.maxTotalCandidateUncompressedBytes = maxTotalCandidateUncompressedBytes
        self.maxCompressionRatio = maxCompressionRatio
        self.maxMetadataCSVBytes = maxMetadataCSVBytes
        self.maxCSVFieldBytes = maxCSVFieldBytes
        self.maxCSVRowBytes = maxCSVRowBytes
        self.maxCSVRows = maxCSVRows
        self.parsingConcurrency = max(1, parsingConcurrency)
        self.cancellationCheckStride = max(1, cancellationCheckStride)
    }

    public static let `default` = WorkoutArchiveSecurityPolicy()
}
