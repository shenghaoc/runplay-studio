import Foundation

/// Imports workouts from FIT (Flexible and Interoperable Data Transfer) files.
///
/// Supports common running activity files with GPS records.
/// Uses FIT binary parser to decode all message types, select the appropriate
/// session, and extract route points with timer-event-based segmentation.
public struct FITImporter: WorkoutImporting {

    public init() {}
    public var supportedExtensions: [String] { ["fit"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        try validateLocalFile(url)

        // Wrap all I/O and parsing errors into WorkoutImportError
        // so upstream code only needs to handle that type.
        let decodedFile: FITDecodedFile
        do {
            let data = try Data(contentsOf: url)
            decodedFile = try FITParser.parse(data: data)
        } catch let error as FITError {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        }

        guard !decodedFile.records.isEmpty else {
            throw WorkoutImportError.missingData("No records found in FIT file")
        }

        // Get the selected session index before decoding
        let selectedSessionIndex = try FITDecoder.selectedSessionIndex(from: decodedFile)

        // Decode records with session selection and segmentation
        let routePoints = try FITDecoder.decode(decodedFile: decodedFile)

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid GPS coordinates found in FIT file")
        }

        // Build metadata from selected session and device info
        let metadata = buildMetadata(
            decodedFile: decodedFile,
            selectedSessionIndex: selectedSessionIndex,
            fileName: url.deletingPathExtension().lastPathComponent,
            routePoints: routePoints
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

    // MARK: - Metadata Population

    /// Build workout metadata from FIT session and device messages.
    private func buildMetadata(
        decodedFile: FITDecodedFile,
        selectedSessionIndex: Int?,
        fileName: String,
        routePoints: [RoutePoint]
    ) -> WorkoutMetadata {
        // Activity type from selected session sport, or first session if none selected
        let activityType: String
        let session = selectedSessionIndex.flatMap { decodedFile.sessions.indices.contains($0) ? decodedFile.sessions[$0] : nil }
            ?? decodedFile.sessions.first

        if let session = session,
           let sport = session.sport,
           let sportType = FITSport(rawValue: sport) {
            activityType = activityTypeFromSport(sportType)
        } else {
            activityType = "running"
        }

        // Start/end dates from route points
        let startDate = routePoints.first?.timestamp
        let endDate = routePoints.last?.timestamp

        // Device name from device info
        let deviceName = buildDeviceName(from: decodedFile.deviceInfo)

        return WorkoutMetadata(
            name: fileName,
            activityType: activityType,
            startDate: startDate,
            endDate: endDate,
            deviceName: deviceName
        )
    }

    /// Convert FIT sport enum to human-readable activity type.
    private func activityTypeFromSport(_ sport: FITSport) -> String {
        switch sport {
        case .running: return "running"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .generic: return "running"
        case .training: return "running"
        default: return "running"
        }
    }

    /// Build device name from device info messages.
    private func buildDeviceName(from deviceInfo: [FITDeviceInfoMessage]) -> String? {
        guard let device = deviceInfo.first else { return nil }

        // Use product name if available
        if let productName = device.productName, !productName.isEmpty {
            return productName
        }

        // Only report device name for well-known manufacturers with product names
        // Don't invent names from unknown numeric combinations
        guard device.manufacturer != nil else { return nil }
        return nil
    }
}
