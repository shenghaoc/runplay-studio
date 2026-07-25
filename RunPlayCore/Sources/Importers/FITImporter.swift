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
        let data = try Data(contentsOf: url)
        return try importWorkout(
            data: data,
            suggestedName: url.deletingPathExtension().lastPathComponent
        )
    }

    public func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
        return try importWorkout(
            data: input.data,
            suggestedName: input.suggestedName.isEmpty
                ? "Imported Run"
                : (input.suggestedName as NSString).deletingPathExtension
        )
    }

    func importWorkout(data: Data, suggestedName: String) throws -> RunWorkout {
        // Wrap all I/O and parsing errors into WorkoutImportError
        // so upstream code only needs to handle that type.
        let decodedFile: FITDecodedFile
        do {
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

        // Resolve the single-workout selection policy, then hand off to the
        // same builder batch import uses. Direct and batch import must never
        // have two implementations of workout construction.
        let selectedSessionIndex = try FITDecoder.selectedSessionIndex(from: decodedFile)
        return try buildSession(
            index: FITSessionMessageIndex.build(decodedFile: decodedFile),
            sessionIndex: selectedSessionIndex,
            suggestedName: suggestedName,
            provenance: nil
        )
    }

    // MARK: - Canonical session builder

    /// Build one workout from an explicitly chosen FIT session.
    ///
    /// Convenience entry point that builds the message index itself. When
    /// importing several sessions from one container, build the index once and
    /// call `buildSession(index:...)` instead.
    public func importSession(
        from decodedFile: FITDecodedFile,
        sessionIndex: Int,
        suggestedName: String,
        provenance: WorkoutImportProvenance?
    ) throws -> RunWorkout {
        try buildSession(
            index: FITSessionMessageIndex.build(decodedFile: decodedFile),
            sessionIndex: sessionIndex,
            suggestedName: suggestedName,
            provenance: provenance
        )
    }

    /// The single implementation of FIT workout construction.
    ///
    /// Owns session-scoped record decoding, timer-event segmentation, metadata,
    /// recorded-lap extraction, normalisation, analysis, source timing warnings,
    /// source-structure version, and provenance.
    ///
    /// - Parameter sessionIndex: `nil` selects the legacy whole-file fallback
    ///   used when the container has no GPS-bearing session.
    func buildSession(
        index: FITSessionMessageIndex,
        sessionIndex: Int?,
        suggestedName: String,
        provenance: WorkoutImportProvenance?
    ) throws -> RunWorkout {
        let decodedFile = index.decodedFile
        let decodedRoute: FITDecodedRouteResult
        if let sessionIndex {
            decodedRoute = try FITDecoder.decodeRawResult(index: index, sessionIndex: sessionIndex)
        } else {
            decodedRoute = try FITDecoder.decodeLegacyWholeFile(decodedFile: decodedFile)
        }
        let routePoints = decodedRoute.routePoints

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid GPS coordinates found in FIT file")
        }

        // Build metadata from selected session and device info
        let metadata = buildMetadata(
            decodedFile: decodedFile,
            selectedSessionIndex: sessionIndex,
            fileName: suggestedName,
            routePoints: routePoints
        )

        // Associate FIT lap messages with the selected session only.
        // Lap messages never create route segments; timer events remain authority.
        let provisionalLaps = provisionalRecordedLaps(
            index: index,
            selectedSessionIndex: sessionIndex,
            sessionEndDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .fit,
            routePoints: routePoints,
            recordedLaps: provisionalLaps
        )
        workout.sourceStructureVersion = RunWorkout.currentSourceStructureVersion
        if let provenance {
            workout.importProvenance = provenance
        }

        // Run analysis (rederives canonical lap metrics from source boundaries)
        let analyzer = WorkoutAnalyzer()
        try analyzer.normalizeAndAnalyze(
            &workout,
            distancePolicy: .useSuppliedDistancesPerSegment,
            sourceInvalidCoordinatePointCount: decodedRoute.invalidCoordinatePointCount
        )
        let timing = timingWarnings(
            decodedFile: decodedFile,
            selectedSessionIndex: sessionIndex,
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
    ///
    /// Lap association itself lives in `FITSessionMessageIndex`, so one lap can
    /// never be handed to two sessions of the same container.
    private func provisionalRecordedLaps(
        index: FITSessionMessageIndex,
        selectedSessionIndex: Int?,
        sessionEndDate: Date?
    ) -> [RecordedLap] {
        let sessionLaps: [FITLapMessage]
        if let selectedSessionIndex {
            sessionLaps = index.laps(for: selectedSessionIndex)
        } else {
            // Legacy whole-file fallback: keep all laps in source order.
            sessionLaps = index.decodedFile.laps
        }

        var result: [RecordedLap] = []
        result.reserveCapacity(sessionLaps.count)

        for (lapIndex, lap) in sessionLaps.enumerated() {
            let startDate = fitDate(lap.startTime)
            var endDate = fitDate(lap.timestamp)

            // Safe end fallback: next lap start, else selected session/route end.
            if endDate == nil {
                if lapIndex + 1 < sessionLaps.count {
                    endDate = fitDate(sessionLaps[lapIndex + 1].startTime)
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
            let reported = reportedMetrics(from: lap)

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

    private func reportedMetrics(from lap: FITLapMessage) -> RecordedLapReportedMetrics? {
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
        guard let fitTimestamp = FITParser.timestampIfValid(fitTimestamp) else { return nil }
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
        // Activity type from selected session sport, or first session if none selected.
        // Single classifier shared with multi-session scan/import.
        let session = selectedSessionIndex.flatMap { decodedFile.sessions.indices.contains($0) ? decodedFile.sessions[$0] : nil }
            ?? decodedFile.sessions.first
        let activityType = FITSportPolicy.activityType(sport: session?.sport)

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
