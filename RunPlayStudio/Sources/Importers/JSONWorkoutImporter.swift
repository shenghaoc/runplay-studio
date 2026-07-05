import Foundation
import CoreLocation

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
struct JSONWorkoutImporter: WorkoutImporting {
    var supportedExtensions: [String] { ["json"] }

    func importWorkout(from url: URL) throws -> RunWorkout {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }

        let data = try Data(contentsOf: url)
        return try importWorkout(from: data)
    }

    func importWorkout(from data: Data) throws -> RunWorkout {
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
    }

    private func convertToWorkout(_ raw: RawWorkout) throws -> RunWorkout {
        guard !raw.routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No route points found")
        }

        let metadata = raw.metadata ?? WorkoutMetadata()
        let source = parseSource(raw.source)

        // Convert raw points and calculate derived values
        var routePoints: [RoutePoint] = []
        var cumulativeDistance: Double = 0
        var startDate = raw.routePoints.first?.timestamp ?? Date()

        for (index, rawPoint) in raw.routePoints.enumerated() {
            let elapsed = rawPoint.elapsedSeconds ?? rawPoint.timestamp.timeIntervalSince(startDate)

            // Calculate distance from previous point
            if index > 0 {
                let prev = raw.routePoints[index - 1]
                let distance = calculateDistance(
                    from: (prev.latitude, prev.longitude),
                    to: (rawPoint.latitude, rawPoint.longitude)
                )
                cumulativeDistance += distance
            }

            let distance = rawPoint.distanceFromStartMeters ?? cumulativeDistance

            // Calculate speed if not provided
            let speed: Double?
            if let s = rawPoint.speedMetersPerSecond {
                speed = s
            } else if index > 0 {
                let prev = raw.routePoints[index - 1]
                let dist = calculateDistance(
                    from: (prev.latitude, prev.longitude),
                    to: (rawPoint.latitude, rawPoint.longitude)
                )
                let time = rawPoint.timestamp.timeIntervalSince(prev.timestamp)
                speed = time > 0 ? dist / time : nil
            } else {
                speed = nil
            }

            // Calculate pace if not provided
            let pace: Double?
            if let p = rawPoint.paceSecondsPerKilometer {
                pace = p
            } else if let s = speed, s > 0 {
                pace = 1000.0 / s
            } else {
                pace = nil
            }

            let point = RoutePoint(
                timestamp: rawPoint.timestamp,
                latitude: rawPoint.latitude,
                longitude: rawPoint.longitude,
                altitudeMeters: rawPoint.altitudeMeters,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: speed,
                paceSecondsPerKilometer: pace,
                heartRateBPM: rawPoint.heartRateBPM,
                cadence: rawPoint.cadence,
                horizontalAccuracy: rawPoint.horizontalAccuracy
            )
            routePoints.append(point)
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

    private func calculateDistance(
        from: (latitude: Double, longitude: Double),
        to: (latitude: Double, longitude: Double)
    ) -> Double {
        let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return fromLocation.distance(from: toLocation)
    }
}

import CoreLocation
