import Foundation

/// A complete running workout with route data, analysis, and metadata.
public struct RunWorkout: Identifiable, Codable, Hashable, Sendable {
    /// Snapshots without a version predate pause-aware analysis.
    public static let legacyAnalysisVersion = 0
    /// Version 5 introduces route-derived recorded-lap analysis.
    /// Version 6 persists raw elevation ascent/descent totals in the summary.
    public static let currentAnalysisVersion = 6
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
    /// Best fixed-distance record windows, computed in the same analysis pass
    /// as segments. `nil` on snapshots that predate record computation — that
    /// absence is the backfill marker, while an empty value means the run
    /// attempted no window. Deliberately not gated on `analysisVersion`.
    public var personalRecords: WorkoutPersonalRecords?
    /// Heart-rate training load. `nil` on snapshots that predate training-load
    /// computation — that absence is the backfill marker, while a present
    /// value whose `profile` differs from the current athlete profile is the
    /// stale marker that drives recompute. Deliberately not gated on
    /// `analysisVersion`, exactly like `personalRecords`.
    public var trainingLoad: TrainingLoadSnapshot?
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
    /// FIT developer-field provenance and diagnostics. Nil for legacy
    /// snapshots and workouts whose source carried no developer data.
    /// Deliberately not gated on any snapshot version: the fields decode as
    /// nil on older snapshots and reimport is the upgrade path.
    public var developerFieldSummary: WorkoutDeveloperFieldSummary?
    /// Standalone time-indexed heart rate, for sources whose route carries no
    /// heart rate at all.
    ///
    /// Nil on every snapshot written before this field existed, and on every
    /// workout imported from FIT/TCX/GPX/JSON where heart rate rides on
    /// `routePoints`. The single-heart-rate-source invariant is enforced at
    /// construction: when `routePoints` carry heart rate this series is
    /// cleared, so the two representations can never both hold data. Read it
    /// through `heartRateSamples`, never directly.
    public var heartRateSeries: [HeartRateSample]?

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
        personalRecords: WorkoutPersonalRecords? = nil,
        trainingLoad: TrainingLoadSnapshot? = nil,
        analysisVersion: Int,
        normalizationVersion: Int = RunWorkout.currentNormalizationVersion,
        sourceStructureVersion: Int = RunWorkout.currentSourceStructureVersion,
        analysisWarnings: [WorkoutAnalysisWarning] = [],
        movementDiagnostics: MovementDiagnostics = .init(),
        qualityDiagnostics: RouteQualityDiagnostics = .empty,
        recordedLapDiagnostics: RecordedLapDiagnostics = .empty,
        routeDistanceSource: RouteDistanceSource = .coordinateDerived,
        routeDistanceProvenance: RouteDistanceProvenance = .legacyUnknown,
        importProvenance: WorkoutImportProvenance? = nil,
        developerFieldSummary: WorkoutDeveloperFieldSummary? = nil,
        heartRateSeries: [HeartRateSample]? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.source = source
        self.routePoints = routePoints
        self.splits = splits
        self.recordedLaps = Self.sanitizedRecordedLaps(recordedLaps)
        self.summary = summary
        self.segments = segments
        self.personalRecords = personalRecords
        self.trainingLoad = trainingLoad
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
        self.developerFieldSummary = developerFieldSummary
        self.heartRateSeries = Self.sanitizedHeartRateSeries(
            heartRateSeries,
            routePoints: routePoints
        )
    }

    /// Enforce the single-heart-rate-source invariant.
    ///
    /// Heart rate lives in `routePoints` or in the standalone series, never
    /// both. When the route points already carry any valid reading the
    /// standalone series is dropped, because a route-bearing source owns its
    /// heart rate and a second copy would silently double-count it in training
    /// load and the summary aggregation.
    ///
    /// An empty or all-invalid series normalizes to `nil` rather than to an
    /// empty array, so snapshots that never had standalone heart rate re-encode
    /// byte for byte identically.
    private static func sanitizedHeartRateSeries(
        _ series: [HeartRateSample]?,
        routePoints: [RoutePoint]
    ) -> [HeartRateSample]? {
        guard let series, !series.isEmpty else { return nil }

        let routeCarriesHeartRate = routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
        if routeCarriesHeartRate { return nil }

        // A series with no valid reading anywhere carries no information; keep
        // the historical nil shape instead of persisting an inert array.
        let hasAnyValidReading = series.contains { sample in
            sample.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
        guard hasAnyValidReading else { return nil }

        // Sort into the elapsed-time domain the consumers assume, then clamp
        // elapsed time monotonically so a series whose source timestamps were
        // slightly out of order cannot produce a negative interval weight.
        let sorted = series.sorted { lhs, rhs in
            if lhs.elapsedSeconds != rhs.elapsedSeconds {
                return lhs.elapsedSeconds < rhs.elapsedSeconds
            }
            return lhs.segmentIndex < rhs.segmentIndex
        }
        var normalized: [HeartRateSample] = []
        normalized.reserveCapacity(sorted.count)
        var previousElapsed: Double = 0
        for sample in sorted {
            let elapsed = max(previousElapsed, sample.elapsedSeconds)
            previousElapsed = elapsed
            normalized.append(
                HeartRateSample(
                    elapsedSeconds: elapsed,
                    heartRateBPM: sample.heartRateBPM,
                    segmentIndex: sample.segmentIndex
                )
            )
        }
        return normalized
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

    /// Visits every heart-rate reading in the workout, from whichever single
    /// source holds it — route points or the standalone series, never both.
    ///
    /// This is *the* decision point for "where does heart rate live", and it
    /// allocates nothing: the summary aggregation uses it so a million-point
    /// route is not copied into a temporary array. `heartRateSamples` is built
    /// on top of it, so both forms resolve the source through this one rule and
    /// cannot diverge.
    ///
    /// The single-source invariant is enforced at construction, so reading both
    /// representations here would be a bug, not a fallback.
    public func forEachHeartRateSample(
        _ body: (HeartRateSample) -> Void
    ) {
        if let series = heartRateSourceSeries {
            for sample in series {
                body(sample)
            }
            return
        }
        for point in routePoints {
            body(
                HeartRateSample(
                    elapsedSeconds: point.elapsedSeconds,
                    heartRateBPM: point.heartRateBPM,
                    segmentIndex: point.routeSegmentIndex
                )
            )
        }
    }

    /// Every heart-rate reading in the workout, from whichever single source
    /// holds it.
    ///
    /// The materializing form of `forEachHeartRateSample`, for consumers that
    /// need the samples as a value rather than as a visit. Training load is the
    /// current one: it builds two route-sized interval arrays and checks
    /// cancellation per sample, so it needs the list anyway.
    ///
    /// Prefer `forEachHeartRateSample` when merely aggregating — a million-point
    /// route must not be copied into a temporary array just to compute a mean.
    public var heartRateSamples: [HeartRateSample] {
        var samples: [HeartRateSample] = []
        samples.reserveCapacity(heartRateSampleCount)
        forEachHeartRateSample { samples.append($0) }
        return samples
    }

    /// The standalone series when it owns this workout's heart rate, else nil.
    ///
    /// The single expression of the resolution rule. Construction has already
    /// made the two representations mutually exclusive, so a non-empty series
    /// always wins and route points are only consulted when it is absent.
    ///
    /// Internal rather than public: `WorkoutTimeline` needs it to keep split and
    /// record-window heart-rate averages on the single accessor, but the public
    /// forms are `forEachHeartRateSample`, `heartRateSamples` and
    /// `heartRateBPM(atRoutePointIndex:)`.
    var heartRateSourceSeries: [HeartRateSample]? {
        guard let series = heartRateSeries, !series.isEmpty else { return nil }
        return series
    }

    private var heartRateSampleCount: Int {
        heartRateSourceSeries?.count ?? routePoints.count
    }

    /// Heart rate for one specific route point, resolved through the single
    /// accessor.
    ///
    /// Replay and the chart scrub readout both address heart rate by route
    /// point index, so they need this rather than the flat sample list.
    ///
    /// When heart rate rides on the route points — every FIT/TCX/GPX/JSON
    /// workout — this returns that point's own reading verbatim, so existing
    /// behaviour is exactly preserved, including duplicate elapsed times. When
    /// heart rate is a standalone series, the point's elapsed time indexes the
    /// series instead: this is what makes an Apple Health export run *with* a
    /// route GPX still show heart rate during replay, because its GPX carries
    /// position, elevation, speed, course and accuracy but no heart rate.
    ///
    /// Returns nil for an out-of-range index or when no reading covers it.
    public func heartRateBPM(atRoutePointIndex index: Int) -> Double? {
        guard routePoints.indices.contains(index) else { return nil }

        guard let series = heartRateSourceSeries else {
            return routePoints[index].heartRateBPM
        }

        let target = routePoints[index].elapsedSeconds
        guard target.isFinite else { return nil }
        return Self.heartRateReading(
            in: series,
            atOrBeforeElapsedSeconds: target
        )
    }

    /// The heart rate that applies at one elapsed time in a sorted series.
    ///
    /// Private rather than an `Array` extension so the sorted-series lookup
    /// adds no public API surface: the ordering it relies on is an invariant of
    /// `sanitizedHeartRateSeries`, and exposing a binary search that only holds
    /// for its own sorted input would invite misuse.
    ///
    /// "At or before" is the hold rule: between two readings the earlier one
    /// still applies, which is how a step-shaped heart-rate trace behaves during
    /// replay and in the chart scrub readout. It is deliberately *not*
    /// interpolated, so a route-less workout never shows a reading the source
    /// did not produce.
    private static func heartRateReading(
        in series: [HeartRateSample],
        atOrBeforeElapsedSeconds elapsedSeconds: Double
    ) -> Double? {
        guard !series.isEmpty, elapsedSeconds.isFinite else { return nil }
        if elapsedSeconds < series[0].elapsedSeconds { return nil }

        // First index whose elapsed time exceeds the target, then step back one.
        // Sound because `sanitizedHeartRateSeries` sorted the series.
        var low = 0
        var high = series.count
        while low < high {
            let middle = (low + high) / 2
            if series[middle].elapsedSeconds <= elapsedSeconds {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return nil }
        return series[low - 1].heartRateBPM
    }

    /// Which representation currently holds this workout's heart rate.
    public var heartRateSampleSource: HeartRateSampleSource {
        if let series = heartRateSeries, !series.isEmpty {
            return .standaloneSeries
        }
        let routeHasHeartRate = routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
        return routeHasHeartRate ? .routePoints : .none
    }

    public var hasHeartRateData: Bool {
        // Deliberately does not materialize `heartRateSamples`: this predicate
        // is reached from list rendering, where an O(N) array per row would be
        // a needless allocation.
        if let series = heartRateSeries {
            return series.contains { sample in
                sample.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
            }
        }
        return routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
    }
    public var hasCadenceData: Bool {
        routePoints.contains { point in
            point.cadence.map(MetricValidation.isValidCadence) ?? false
        }
    }

    public var hasPowerData: Bool {
        routePoints.contains { point in
            point.powerWatts.map(MetricValidation.isValidPower) ?? false
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
        case personalRecords, trainingLoad
        case analysisVersion, normalizationVersion, sourceStructureVersion
        case analysisWarnings, movementDiagnostics
        case qualityDiagnostics, recordedLapDiagnostics
        case routeDistanceSource, routeDistanceProvenance, importProvenance
        case developerFieldSummary
        case heartRateSeries
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
        personalRecords = try container.decodeIfPresent(
            WorkoutPersonalRecords.self,
            forKey: .personalRecords
        )
        trainingLoad = try container.decodeIfPresent(
            TrainingLoadSnapshot.self,
            forKey: .trainingLoad
        )
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
        developerFieldSummary = try container.decodeIfPresent(
            WorkoutDeveloperFieldSummary.self,
            forKey: .developerFieldSummary
        )
        // Absent on every snapshot written before standalone heart rate
        // existed; those snapshots all carried heart rate on route points.
        // Route through the same sanitizer as construction so a hand-edited or
        // cross-imported snapshot cannot break the single-source invariant.
        heartRateSeries = Self.sanitizedHeartRateSeries(
            try container.decodeIfPresent([HeartRateSample].self, forKey: .heartRateSeries),
            routePoints: routePoints
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
        try container.encodeIfPresent(personalRecords, forKey: .personalRecords)
        try container.encodeIfPresent(trainingLoad, forKey: .trainingLoad)
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
        try container.encodeIfPresent(developerFieldSummary, forKey: .developerFieldSummary)
        // Omitted when nil, so snapshots written before standalone heart rate
        // existed re-encode byte for byte identically.
        try container.encodeIfPresent(heartRateSeries, forKey: .heartRateSeries)
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
