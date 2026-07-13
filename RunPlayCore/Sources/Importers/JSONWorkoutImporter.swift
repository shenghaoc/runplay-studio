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

        routePoints = RoutePointSanitizer.normalize(
            routePoints,
            distancePolicy: hasCompleteSuppliedDistanceSeries
                ? .useSuppliedDistancesPerSegment
                : .computeFromCoordinates
        )

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid route points found")
        }

        // Build workout and analyze
        var workout = RunWorkout(
            metadata: metadata,
            source: source,
            routePoints: routePoints
        )

        // Run analysis
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        return workout
    }

    private func parseSource(_ source: String?) -> WorkoutSource {
        guard let source = source else { return .json }
        return WorkoutSource(rawValue: source) ?? .json
    }
}
