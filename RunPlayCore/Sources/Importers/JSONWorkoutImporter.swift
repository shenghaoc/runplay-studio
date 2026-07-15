import Foundation

/// Imports workouts from JSON files.
///
/// Expected JSON structure:
/// ```json
/// {
///   "metadata": { "name": "...", "activityType": "running", ... },
///   "source": "json",
///   "routePoints": [ { "timestamp": "...", "latitude": ..., ... } ]
/// }
/// ```
public struct JSONWorkoutImporter: WorkoutImporting {

    public init() {}
    public var supportedExtensions: [String] { ["json"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        try validateLocalFile(url)
        let data = try Data(contentsOf: url)
        return try importWorkout(from: data)
    }

    public func importWorkout(from data: Data) throws -> RunWorkout {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let raw = try decoder.decode(RawWorkout.self, from: data)
        return try convertToWorkout(raw)
    }

    // MARK: - Private

    private struct RawWorkout: Codable {
        var metadata: WorkoutMetadata?
        var source: String?
        var routePoints: [RawRoutePoint]
        var recordedLaps: [RecordedLap]?
        var sourceStructureVersion: Int?
        var splits: [RunSplit]?
    }

    private struct RawRoutePoint: Codable {
        var timestamp: Date
        var latitude: Double
        var longitude: Double
        var altitudeMeters: Double?
        var distanceFromStartMeters: Double?
        var elapsedSeconds: Double?
        var speedMetersPerSecond: Double?
        var paceSecondsPerKilometer: Double?
        var heartRateBPM: Double?
        var cadence: Double?
        var horizontalAccuracy: Double?
        var routeSegmentIndex: Int?
    }

    private func convertToWorkout(_ raw: RawWorkout) throws -> RunWorkout {
        guard !raw.routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No route points found")
        }

        let metadata = raw.metadata ?? WorkoutMetadata()
        let source = parseSource(raw.source)

        let validRawPoints = raw.routePoints.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
        }
        let invalidCoordinatePointCount = raw.routePoints.count - validRawPoints.count
        let hasCompleteSuppliedDistanceSeries = !validRawPoints.isEmpty
            && validRawPoints.allSatisfy { point in
                guard let distance = point.distanceFromStartMeters else { return false }
                return distance.isFinite && distance >= 0
            }

        var routePoints: [RoutePoint] = []
        let startDate = raw.routePoints.first?.timestamp ?? Date()

        for rawPoint in raw.routePoints {
            guard GeoDistance.isValidCoordinate(lat: rawPoint.latitude, lon: rawPoint.longitude) else {
                continue
            }

            let elapsed = rawPoint.elapsedSeconds ?? rawPoint.timestamp.timeIntervalSince(startDate)

            let point = RoutePoint(
                timestamp: rawPoint.timestamp,
                latitude: rawPoint.latitude,
                longitude: rawPoint.longitude,
                altitudeMeters: rawPoint.altitudeMeters,
                distanceFromStartMeters: rawPoint.distanceFromStartMeters ?? 0,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: rawPoint.speedMetersPerSecond,
                paceSecondsPerKilometer: rawPoint.paceSecondsPerKilometer,
                heartRateBPM: rawPoint.heartRateBPM,
                cadence: rawPoint.cadence,
                horizontalAccuracy: rawPoint.horizontalAccuracy,
                routeSegmentIndex: rawPoint.routeSegmentIndex ?? 0
            )
            routePoints.append(point)
        }

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid route points found")
        }

        // Optional recorded laps from native JSON. Malformed values are
        // sanitised by RecordedLap's initializer; calculated splits stay separate.
        let provisionalLaps = sanitizeRecordedLaps(raw.recordedLaps ?? [])

        // Build workout and analyze
        var workout = RunWorkout(
            metadata: metadata,
            source: source,
            routePoints: routePoints,
            recordedLaps: provisionalLaps
        )
        if let version = raw.sourceStructureVersion {
            workout.sourceStructureVersion = max(0, version)
        } else {
            // Without an explicit version: an explicit recordedLaps key means the
            // file is structure-aware (possibly empty). Omitting the key is the
            // pre-feature shape and decodes as legacy.
            workout.sourceStructureVersion = raw.recordedLaps != nil
                ? RunWorkout.currentSourceStructureVersion
                : RunWorkout.legacySourceStructureVersion
        }

        // Run analysis (rederives canonical lap metrics; does not invent laps)
        let analyzer = WorkoutAnalyzer()
        try analyzer.normalizeAndAnalyze(
            &workout,
            distancePolicy: hasCompleteSuppliedDistanceSeries
                ? .useSuppliedDistancesWhenValid
                : .computeFromCoordinates,
            sourceInvalidCoordinatePointCount: invalidCoordinatePointCount
        )

        return workout
    }

    private func sanitizeRecordedLaps(_ laps: [RecordedLap]) -> [RecordedLap] {
        laps.enumerated().map { index, lap in
            // Re-run through the initializer for finite/non-negative sanitization.
            RecordedLap(
                id: lap.id,
                lapIndex: lap.lapIndex > 0 ? lap.lapIndex : index + 1,
                source: lap.source,
                trigger: lap.trigger,
                sourceStartDate: lap.sourceStartDate,
                sourceEndDate: lap.sourceEndDate,
                startElapsedSeconds: lap.startElapsedSeconds,
                endElapsedSeconds: lap.endElapsedSeconds,
                startDistanceMeters: lap.startDistanceMeters,
                endDistanceMeters: lap.endDistanceMeters,
                distanceMeters: lap.distanceMeters,
                elapsedSeconds: lap.elapsedSeconds,
                activeSeconds: lap.activeSeconds,
                movingSeconds: lap.movingSeconds,
                activePaceSecondsPerKilometer: lap.activePaceSecondsPerKilometer,
                movingPaceSecondsPerKilometer: lap.movingPaceSecondsPerKilometer,
                elapsedPaceSecondsPerKilometer: lap.elapsedPaceSecondsPerKilometer,
                averageHeartRateBPM: lap.averageHeartRateBPM,
                maximumHeartRateBPM: lap.maximumHeartRateBPM,
                averageCadence: lap.averageCadence,
                elevationGainMeters: lap.elevationGainMeters,
                elevationLossMeters: lap.elevationLossMeters,
                reportedMetrics: lap.reportedMetrics
            )
        }
    }

    private func parseSource(_ source: String?) -> WorkoutSource {
        guard let source = source else { return .json }
        return WorkoutSource(rawValue: source) ?? .json
    }
}
