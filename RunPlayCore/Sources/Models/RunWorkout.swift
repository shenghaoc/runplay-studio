import Foundation

/// A complete running workout with route data, analysis, and metadata.
public struct RunWorkout: Identifiable, Codable, Hashable, Sendable {
    /// Snapshots without a version predate pause-aware analysis.
    public static let legacyAnalysisVersion = 0
    /// Version 5 introduces route-derived recorded-lap analysis.
    public static let currentAnalysisVersion = 5
    /// Snapshots without this version predate route-quality normalization.
    public static let legacyNormalizationVersion = 0
    public static let currentNormalizationVersion = 1
    /// Snapshots without this version predate recorded-lap source preservation.
    /// Version 0: source FIT/TCX lap messages may have been discarded.
    /// Version 1: importers preserve source-recorded laps (possibly empty).
    public static let legacySourceStructureVersion = 0
    public static let currentSourceStructureVersion = 1

    public let id: UUID
    public var metadata: WorkoutMetadata
    public var source: WorkoutSource
    public var routePoints: [RoutePoint]
    /// Calculated regular distance intervals (usually 1 km). Independent of recorded laps.
    public var splits: [RunSplit]
    /// Source-recorded lap boundaries preserved from the import file.
    public var recordedLaps: [RecordedLap]
    public var summary: RunSummary
    public var segments: [SegmentHighlight]
    public var analysisVersion: Int
    public var normalizationVersion: Int
    /// Whether source-structure fields such as recorded laps were preserved at import.
    public var sourceStructureVersion: Int
    public var analysisWarnings: [WorkoutAnalysisWarning]
    /// Persisted detector metadata; detailed interval state is derived at runtime.
    public var movementDiagnostics: MovementDiagnostics
    public var qualityDiagnostics: RouteQualityDiagnostics
    public var recordedLapDiagnostics: RecordedLapDiagnostics
    public var routeDistanceSource: RouteDistanceSource
    public var routeDistanceProvenance: RouteDistanceProvenance
    /// Optional import provenance (provider, content hash). Nil for legacy snapshots.
    public var importProvenance: WorkoutImportProvenance?

    public init(
        id: UUID = UUID(),
        metadata: WorkoutMetadata = WorkoutMetadata(),
        source: WorkoutSource = .unknown,
        routePoints: [RoutePoint] = [],
        splits: [RunSplit] = [],
        recordedLaps: [RecordedLap] = [],
        summary: RunSummary = RunSummary(),
        segments: [SegmentHighlight] = []
    ) {
        self.init(
            id: id,
            metadata: metadata,
            source: source,
            routePoints: routePoints,
            splits: splits,
            recordedLaps: recordedLaps,
            summary: summary,
            segments: segments,
            analysisVersion: RunWorkout.currentAnalysisVersion,
            normalizationVersion: RunWorkout.currentNormalizationVersion,
            sourceStructureVersion: RunWorkout.currentSourceStructureVersion,
            analysisWarnings: [],
            movementDiagnostics: .init(),
            qualityDiagnostics: .empty,
            recordedLapDiagnostics: .empty,
            routeDistanceSource: .coordinateDerived,
            routeDistanceProvenance: .legacyUnknown
        )
    }

    public init(
        id: UUID = UUID(),
        metadata: WorkoutMetadata = WorkoutMetadata(),
        source: WorkoutSource = .unknown,
        routePoints: [RoutePoint] = [],
        splits: [RunSplit] = [],
        recordedLaps: [RecordedLap] = [],
        summary: RunSummary = RunSummary(),
        segments: [SegmentHighlight] = [],
        analysisVersion: Int,
        normalizationVersion: Int = RunWorkout.currentNormalizationVersion,
        sourceStructureVersion: Int = RunWorkout.currentSourceStructureVersion,
        analysisWarnings: [WorkoutAnalysisWarning] = [],
        movementDiagnostics: MovementDiagnostics = .init(),
        qualityDiagnostics: RouteQualityDiagnostics = .empty,
        recordedLapDiagnostics: RecordedLapDiagnostics = .empty,
        routeDistanceSource: RouteDistanceSource = .coordinateDerived,
        routeDistanceProvenance: RouteDistanceProvenance = .legacyUnknown,
        importProvenance: WorkoutImportProvenance? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.source = source
        self.routePoints = routePoints
        self.splits = splits
        self.recordedLaps = Self.sanitizedRecordedLaps(recordedLaps)
        self.summary = summary
        self.segments = segments
        self.analysisVersion = max(RunWorkout.legacyAnalysisVersion, analysisVersion)
        self.normalizationVersion = max(RunWorkout.legacyNormalizationVersion, normalizationVersion)
        self.sourceStructureVersion = max(RunWorkout.legacySourceStructureVersion, sourceStructureVersion)
        self.analysisWarnings = analysisWarnings
        self.movementDiagnostics = movementDiagnostics
        self.qualityDiagnostics = qualityDiagnostics
        self.recordedLapDiagnostics = Self.sanitizedRecordedLapDiagnostics(recordedLapDiagnostics)
        self.routeDistanceSource = routeDistanceSource
        self.routeDistanceProvenance = routeDistanceProvenance
        self.importProvenance = importProvenance
    }

    /// Cached medium-date/short-time formatter for the unnamed-workout fallback.
    ///
    /// Deliberately a cached `DateFormatter` rather than `Date.formatted(date:time:)`:
    /// `Date.FormatStyle` has no `.medium` date style, so `.abbreviated` would change
    /// the rendered string in locales such as `de_DE`, `ja_JP`, and `zh_Hans_CN`, and it
    /// measures slower than the cached formatter it would replace. See the 2026-07-30
    /// entry in `.jules/bolt.md`.
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Display name for the workout.
    public var displayName: String {
        if let name = metadata.name, !name.isEmpty {
            return name
        }
        if let date = metadata.startDate {
            return RunWorkout.displayFormatter.string(from: date)
        }
        return "Untitled Run"
    }

    public var pointCount: Int { routePoints.count }
    public var hasAltitudeData: Bool { routePoints.contains { $0.altitudeMeters != nil } }
    public var hasHeartRateData: Bool {
        routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
    }
    public var hasCadenceData: Bool {
        routePoints.contains { point in
            point.cadence.map(MetricValidation.isValidCadence) ?? false
        }
    }

    /// Whether this snapshot may be missing discarded source laps.
    public var mayRequireReimportForRecordedLaps: Bool {
        sourceStructureVersion < RunWorkout.currentSourceStructureVersion
            && recordedLaps.isEmpty
            && (source == .fit || source == .tcx)
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, metadata, source, routePoints, splits, recordedLaps, summary, segments
        case analysisVersion, normalizationVersion, sourceStructureVersion
        case analysisWarnings, movementDiagnostics
        case qualityDiagnostics, recordedLapDiagnostics
        case routeDistanceSource, routeDistanceProvenance, importProvenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        metadata = try container.decode(WorkoutMetadata.self, forKey: .metadata)
        source = try container.decode(WorkoutSource.self, forKey: .source)
        routePoints = try container.decode([RoutePoint].self, forKey: .routePoints)
        splits = try container.decode([RunSplit].self, forKey: .splits)
        let decodedLapCollection = try container.decodeIfPresent(
            LossyRecordedLapCollection.self,
            forKey: .recordedLaps
        )
        recordedLaps = Self.sanitizedRecordedLaps(decodedLapCollection?.values ?? [])
        let structurallyMalformedLapCount = decodedLapCollection?.malformedElementCount ?? 0
        summary = try container.decode(RunSummary.self, forKey: .summary)
        segments = try container.decode([SegmentHighlight].self, forKey: .segments)
        analysisVersion = try container.decodeIfPresent(Int.self, forKey: .analysisVersion)
            ?? RunWorkout.legacyAnalysisVersion
        normalizationVersion = try container.decodeIfPresent(Int.self, forKey: .normalizationVersion)
            ?? RunWorkout.legacyNormalizationVersion
        sourceStructureVersion = try container.decodeIfPresent(Int.self, forKey: .sourceStructureVersion)
            ?? RunWorkout.legacySourceStructureVersion
        analysisWarnings = try container.decodeIfPresent([WorkoutAnalysisWarning].self, forKey: .analysisWarnings) ?? []
        movementDiagnostics = try container.decodeIfPresent(
            MovementDiagnostics.self, forKey: .movementDiagnostics
        ) ?? .init()
        qualityDiagnostics = try container.decodeIfPresent(
            RouteQualityDiagnostics.self,
            forKey: .qualityDiagnostics
        ) ?? .empty
        recordedLapDiagnostics = Self.sanitizedRecordedLapDiagnostics(
            try container.decodeIfPresent(
                RecordedLapDiagnostics.self,
                forKey: .recordedLapDiagnostics
            ) ?? .empty
        )
        if structurallyMalformedLapCount > 0 {
            recordedLapDiagnostics = recordedLapDiagnostics.includingStructurallyMalformedLaps(
                structurallyMalformedLapCount,
                validLapCount: recordedLaps.count
            )
            if !analysisWarnings.contains(.recordedLapsMalformedSkipped) {
                analysisWarnings.append(.recordedLapsMalformedSkipped)
            }
        }
        routeDistanceSource = try container.decodeIfPresent(
            RouteDistanceSource.self,
            forKey: .routeDistanceSource
        ) ?? .legacyUnknown
        routeDistanceProvenance = try container.decodeIfPresent(
            RouteDistanceProvenance.self,
            forKey: .routeDistanceProvenance
        ) ?? .legacyUnknown
        importProvenance = try container.decodeIfPresent(
            WorkoutImportProvenance.self,
            forKey: .importProvenance
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(source, forKey: .source)
        try container.encode(routePoints, forKey: .routePoints)
        try container.encode(splits, forKey: .splits)
        try container.encode(recordedLaps, forKey: .recordedLaps)
        try container.encode(summary, forKey: .summary)
        try container.encode(segments, forKey: .segments)
        try container.encode(analysisVersion, forKey: .analysisVersion)
        try container.encode(normalizationVersion, forKey: .normalizationVersion)
        try container.encode(sourceStructureVersion, forKey: .sourceStructureVersion)
        try container.encode(analysisWarnings, forKey: .analysisWarnings)
        try container.encode(movementDiagnostics, forKey: .movementDiagnostics)
        try container.encode(qualityDiagnostics, forKey: .qualityDiagnostics)
        try container.encode(recordedLapDiagnostics, forKey: .recordedLapDiagnostics)
        try container.encode(routeDistanceSource, forKey: .routeDistanceSource)
        try container.encode(routeDistanceProvenance, forKey: .routeDistanceProvenance)
        try container.encodeIfPresent(importProvenance, forKey: .importProvenance)
    }

    private static func sanitizedRecordedLaps(_ laps: [RecordedLap]) -> [RecordedLap] {
        laps.enumerated().map { index, lap in
            lap.sanitized(lapIndex: index + 1)
        }
    }

    private static func sanitizedRecordedLapDiagnostics(
        _ diagnostics: RecordedLapDiagnostics
    ) -> RecordedLapDiagnostics {
        RecordedLapDiagnostics(
            sourceLapCount: diagnostics.sourceLapCount,
            importedLapCount: diagnostics.importedLapCount,
            malformedLapCount: diagnostics.malformedLapCount,
            clampedBoundaryCount: diagnostics.clampedBoundaryCount,
            timeMismatchCount: diagnostics.timeMismatchCount,
            distanceMismatchCount: diagnostics.distanceMismatchCount,
            triggersAvailable: diagnostics.triggersAvailable,
            requiresReimportForSourceLaps: diagnostics.requiresReimportForSourceLaps
        )
    }

}
