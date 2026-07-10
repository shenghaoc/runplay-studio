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
        try validateLocalFile(url)

        // Wrap all I/O and parsing errors into WorkoutImportError
        // so upstream code only needs to handle that type.
        let records: [FITRecordMessage]
        do {
            let data = try Data(contentsOf: url)
            records = try FITParser.parse(data: data)
        } catch let error as FITError {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        } catch {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        }

        guard !records.isEmpty else {
            throw WorkoutImportError.missingData("No records found in FIT file")
        }

        let gpsRecords = records.filter { record in
            guard let lat = record.positionLat, let lon = record.positionLong else {
                return false
            }
            return lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate
        }

        guard !gpsRecords.isEmpty else {
            throw WorkoutImportError.missingData("No valid GPS coordinates found in FIT file")
        }

        let hasAnyTimestamp = gpsRecords.contains { record in
            guard let timestamp = record.timestamp else { return false }
            return timestamp != FITParser.invalidUint32
        }
        guard hasAnyTimestamp else {
            throw WorkoutImportError.missingData("FIT file has no timestamps; cannot compute pace or duration")
        }

        // Decode records into route points (pass already-filtered GPS records)
        let routePoints = FITDecoder.decode(records: gpsRecords)

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
