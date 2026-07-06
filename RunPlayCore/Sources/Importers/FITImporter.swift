import Foundation

/// Imports workouts from FIT (Flexible and Interoperable Data Transfer) files.
///
/// Supports common running activity files with GPS records.
/// Uses FIT binary parser to extract record messages with
/// timestamps, coordinates, altitude, distance, speed, heart rate, and cadence.
public struct FITImporter: WorkoutImporting {

    public init() {}
    public var supportedExtensions: [String] { ["fit"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }

        let data = try Data(contentsOf: url)

        // Parse FIT binary data
        let records = try FITParser.parse(data: data)

        guard !records.isEmpty else {
            throw WorkoutImportError.missingData("No records found in FIT file")
        }

        // Decode records into route points
        let routePoints = FITDecoder.decode(records: records)

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid GPS coordinates found in FIT file")
        }

        // Build metadata
        let metadata = WorkoutMetadata(
            name: url.deletingPathExtension().lastPathComponent,
            activityType: "running",
            startDate: routePoints.first?.timestamp,
            endDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .fit,
            routePoints: routePoints
        )

        // Run analysis
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        return workout
    }
}
