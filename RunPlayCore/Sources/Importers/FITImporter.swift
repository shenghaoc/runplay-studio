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
            decodedFile = try FITParser.parse(data: data, isCancelled: { Task.isCancelled })
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
        let decodedRoute = try FITDecoder.decodeRawResult(decodedFile: decodedFile)
        let routePoints = decodedRoute.routePoints

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

        // Associate FIT lap messages with the selected session only.
        // Lap messages never create route segments; timer events remain authority.
        let provisionalLaps = provisionalRecordedLaps(
            from: decodedFile,
            selectedSessionIndex: selectedSessionIndex,
            sessionEndDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .fit,
            routePoints: routePoints,
            recordedLaps: provisionalLaps
        )
        workout.sourceStructureVersion = RunWorkout.currentSourceStructureVersion

        // Run analysis (rederives canonical lap metrics from source boundaries)
        let analyzer = WorkoutAnalyzer()
        try analyzer.normalizeAndAnalyze(
            &workout,
            distancePolicy: .useSuppliedDistancesPerSegment,
            sourceInvalidCoordinatePointCount: decodedRoute.invalidCoordinatePointCount
        )
        let timing = timingWarnings(
            decodedFile: decodedFile,
            selectedSessionIndex: selectedSessionIndex,
            summary: workout.summary
        )
        for warning in timing where !workout.analysisWarnings.contains(warning) {
            workout.analysisWarnings.append(warning)
        }

        return workout
    }

    // MARK: - Recorded lap extraction

    /// Build provisional recorded laps from FIT lap messages for the selected session.
    ///
    /// Preserves original message order. Malformed selected-session laps are
    /// retained provisionally so `RecordedLapAnalyzer` can diagnose and skip
    /// them without rejecting the route. Empty collections are valid.
    private func provisionalRecordedLaps(
        from decodedFile: FITDecodedFile,
        selectedSessionIndex: Int?,
        sessionEndDate: Date?
    ) -> [RecordedLap] {
        let sessionLaps = filterLaps(
            decodedFile.laps,
            selectedSessionIndex: selectedSessionIndex,
            sessions: decodedFile.sessions
        )

        var result: [RecordedLap] = []
        result.reserveCapacity(sessionLaps.count)

        for (index, lap) in sessionLaps.enumerated() {
            let startDate = fitDate(lap.startTime)
            var endDate = fitDate(lap.timestamp)

            // Safe end fallback: next lap start, else selected session/route end.
            if endDate == nil {
                if index + 1 < sessionLaps.count {
                    endDate = fitDate(sessionLaps[index + 1].startTime)
                }
                if endDate == nil {
                    endDate = sessionEndDate
                }
            }

            // Safe start fallback from end and reported elapsed only when totals exist.
            var resolvedStart = startDate
            if resolvedStart == nil,
               let end = endDate,
               let elapsed = decodedSeconds(lap.totalElapsedTime),
               elapsed > 0 {
                resolvedStart = end.addingTimeInterval(-elapsed)
            }

            let trigger = RecordedLapTrigger.fromFITLapTrigger(lap.lapTrigger)
            let reported = reportedMetrics(from: lap, trigger: trigger)

            result.append(.provisional(
                lapIndex: result.count + 1,
                source: .fit,
                trigger: trigger,
                sourceStartDate: resolvedStart,
                sourceEndDate: endDate,
                reportedMetrics: reported
            ))
        }

        return result
    }

    /// Keep only laps that belong to the selected session timeframe.
    private func filterLaps(
        _ laps: [FITLapMessage],
        selectedSessionIndex: Int?,
        sessions: [FITSessionMessage]
    ) -> [FITLapMessage] {
        guard let selectedSessionIndex,
              sessions.indices.contains(selectedSessionIndex)
        else {
            // Legacy fallback (no session): keep all laps in source order.
            return laps
        }

        let session = sessions[selectedSessionIndex]
        if let firstLapIndex = session.firstLapIndex,
           firstLapIndex != FITParser.invalidUint16,
           let numberOfLaps = session.numberOfLaps,
           numberOfLaps != FITParser.invalidUint16 {
            // FIT `message_index` reserves its upper bits for flags. Session
            // association uses the lower 12-bit ordinal, not the lap array offset.
            let lowerBound = Int(firstLapIndex & 0x0FFF)
            let upperBound = lowerBound + Int(numberOfLaps)
            let indexedLaps = laps.filter { lap in
                guard let rawIndex = lap.messageIndex,
                      rawIndex != FITParser.invalidUint16
                else {
                    return false
                }
                let index = Int(rawIndex & 0x0FFF)
                return index >= lowerBound && index < upperBound
            }
            if indexedLaps.count == Int(numberOfLaps) {
                return indexedLaps
            }
        }

        // With one session there is no cross-session ambiguity, so retain even
        // boundaryless messages and let the analyzer diagnose malformed laps.
        if sessions.count == 1 {
            return laps
        }

        let sessionStart = session.startTime
            ?? session.timestamp.flatMap { end -> UInt32? in
                guard let elapsed = session.totalElapsedTime, elapsed != FITParser.invalidUint32 else {
                    return nil
                }
                let seconds = elapsed / 1_000
                guard seconds <= end else { return nil }
                return end - seconds
            }
        let sessionEnd = session.timestamp

        return laps.filter { lap in
            // Prefer start_time; fall back to end timestamp for membership.
            let anchor = lap.startTime ?? lap.timestamp
            guard let anchor else { return false }
            if let sessionStart, anchor < sessionStart { return false }
            if let sessionEnd, anchor > sessionEnd { return false }
            // Also reject laps that clearly end before the session starts.
            if let lapEnd = lap.timestamp, let sessionStart, lapEnd < sessionStart {
                return false
            }
            return true
        }
    }

    private func reportedMetrics(
        from lap: FITLapMessage,
        trigger: RecordedLapTrigger
    ) -> RecordedLapReportedMetrics? {
        let avgSpeed: Double?
        if let enhanced = lap.enhancedAverageSpeed, enhanced != FITParser.invalidUint32 {
            avgSpeed = FITParser.enhancedSpeedToMPS(enhanced)
        } else if let legacy = lap.averageSpeed, legacy != FITParser.invalidUint16 {
            avgSpeed = Double(legacy) / 1000
        } else {
            avgSpeed = nil
        }

        let maxSpeed: Double?
        if let enhanced = lap.enhancedMaximumSpeed, enhanced != FITParser.invalidUint32 {
            maxSpeed = FITParser.enhancedSpeedToMPS(enhanced)
        } else if let legacy = lap.maximumSpeed, legacy != FITParser.invalidUint16 {
            maxSpeed = Double(legacy) / 1000
        } else {
            maxSpeed = nil
        }

        let metrics = RecordedLapReportedMetrics(
            elapsedSeconds: decodedSeconds(lap.totalElapsedTime),
            timerSeconds: decodedSeconds(lap.totalTimerTime),
            distanceMeters: decodedDistance(lap.totalDistance),
            ascentMeters: decodedAscent(lap.totalAscent),
            descentMeters: decodedAscent(lap.totalDescent),
            averageHeartRateBPM: decodedHR(lap.averageHeartRate),
            maximumHeartRateBPM: decodedHR(lap.maximumHeartRate),
            averageCadence: decodedCadence(lap.averageCadence),
            averageSpeedMetersPerSecond: avgSpeed,
            maximumSpeedMetersPerSecond: maxSpeed,
            calories: decodedCalories(lap.totalCalories),
            rawTriggerValue: lap.lapTrigger.map { String($0) }
        )
        return metrics.isEmpty ? nil : metrics
    }

    private func fitDate(_ fitTimestamp: UInt32?) -> Date? {
        guard let fitTimestamp, fitTimestamp != FITParser.invalidUint32 else { return nil }
        return FITParser.timestampToDate(fitTimestamp)
    }

    private func decodedDistance(_ scaled: UInt32?) -> Double? {
        guard let scaled, scaled != FITParser.invalidUint32 else { return nil }
        return FITParser.scaledDistanceToMeters(scaled)
    }

    private func decodedAscent(_ value: UInt16?) -> Double? {
        guard let value, value != FITParser.invalidUint16 else { return nil }
        return Double(value)
    }

    private func decodedHR(_ value: UInt8?) -> Double? {
        guard let value, value != FITParser.invalidUint8 else { return nil }
        return Double(value)
    }

    private func decodedCadence(_ value: UInt8?) -> Double? {
        guard let value, value != FITParser.invalidUint8 else { return nil }
        return Double(value)
    }

    private func decodedCalories(_ value: UInt16?) -> Double? {
        guard let value, value != FITParser.invalidUint16 else { return nil }
        return Double(value)
    }

    /// FIT session totals are validation signals only. Route timestamps and
    /// route-segment boundaries remain the cross-format source of truth.
    private func timingWarnings(
        decodedFile: FITDecodedFile,
        selectedSessionIndex: Int?,
        summary: RunSummary
    ) -> [WorkoutAnalysisWarning] {
        guard let selectedSessionIndex,
              decodedFile.sessions.indices.contains(selectedSessionIndex)
        else {
            return []
        }

        let session = decodedFile.sessions[selectedSessionIndex]
        var warnings: [WorkoutAnalysisWarning] = []

        if let sourceElapsed = decodedSeconds(session.totalElapsedTime),
           differsMaterially(sourceElapsed, from: summary.totalElapsedSeconds) {
            warnings.append(.sourceElapsedTimeMismatch)
        }
        if let sourceActive = decodedSeconds(session.totalTimerTime),
           differsMaterially(sourceActive, from: summary.totalActiveSeconds) {
            warnings.append(.sourceActiveTimeMismatch)
        }

        return warnings
    }

    private func decodedSeconds(_ milliseconds: UInt32?) -> Double? {
        guard let milliseconds, milliseconds != FITParser.invalidUint32 else { return nil }
        return Double(milliseconds) / 1000
    }

    private func differsMaterially(_ source: Double, from route: Double) -> Bool {
        guard source.isFinite, route.isFinite, source >= 0, route >= 0 else { return false }
        let tolerance = max(5, route * 0.02)
        return abs(source - route) > tolerance
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
