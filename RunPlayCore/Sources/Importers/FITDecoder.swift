import Foundation

/// Decodes FIT record messages into RoutePoints.
///
/// Handles coordinate conversion, scaling, validation, session selection,
/// timer-event-based route segmentation, and enhanced metric decoding.
public struct FITDecoder {

    public init() {}

    /// Session selection result.
    public enum SessionSelection: Sendable {
        /// Exactly one GPS-bearing running session found.
        case selected(FITSessionMessage, index: Int)
        /// No session messages but valid GPS records exist (legacy fallback).
        case legacyFallback
    }

    /// Convert a decoded FIT file to RoutePoints with session-aware segmentation.
    ///
    /// Implements the session selection policy:
    /// - No sessions but valid GPS records: legacy fallback
    /// - Exactly one GPS-bearing running session: select it
    /// - Non-running sessions + one running session: select running
    /// - Multiple GPS-bearing running sessions: reject as ambiguous
    /// - Non-running only: reject
    public static func decode(decodedFile: FITDecodedFile) throws -> [RoutePoint] {
        let selection = try selectSession(from: decodedFile)
        let records: [FITRecordMessage]
        let segments: [RouteSegment]
        let usesTimerSegmentation: Bool

        switch selection {
        case .selected(let session, _):
            // Filter records to those within the session timeframe
            records = try filterRecords(
                decodedFile.records,
                for: session,
                totalSessionCount: decodedFile.sessions.count
            )
            let sessionEvents = try filterEvents(
                decodedFile.events,
                for: session,
                totalSessionCount: decodedFile.sessions.count
            )
            // Build segments from timer events
            segments = buildSegments(
                events: sessionEvents,
                records: records
            )
            usesTimerSegmentation = sessionEvents.contains {
                $0.timerEventType != nil && $0.timestamp != nil
            }
        case .legacyFallback:
            records = decodedFile.records
            segments = []
            usesTimerSegmentation = false
        }

        return try decodeRecordsToRoutePoints(
            records: records,
            segments: segments,
            usesTimerSegmentation: usesTimerSegmentation
        )
    }

    /// Select a session and return both the session and its index.
    /// Returns nil if legacy fallback should be used.
    public static func selectedSessionIndex(from decodedFile: FITDecodedFile) throws -> Int? {
        let selection = try selectSession(from: decodedFile)
        switch selection {
        case .selected(_, let index):
            return index
        case .legacyFallback:
            return nil
        }
    }

    /// Convert FIT record messages to RoutePoints (legacy API).
    ///
    /// Filters out records without valid GPS coordinates.
    /// Delegates distance normalization and timestamp ordering to `RoutePointSanitizer`.
    public static func decode(records: [FITRecordMessage]) -> [RoutePoint] {
        guard !records.isEmpty else { return [] }

        let validRecords = records.filter { record in
            guard let lat = record.positionLat, let lon = record.positionLong else {
                return false
            }
            return lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate
        }

        guard !validRecords.isEmpty else { return [] }

        let resolvedTimestamps = RouteTimestampResolver.resolve(
            validRecords.map { record in
                guard let timestamp = record.timestamp, timestamp != FITParser.invalidUint32 else {
                    return nil
                }
                return FITParser.timestampToDate(timestamp)
            }
        )
        guard let resolvedTimestamps, let startDate = resolvedTimestamps.first else {
            return []
        }

        var routePoints: [RoutePoint] = []
        routePoints.reserveCapacity(validRecords.count)

        for (index, record) in validRecords.enumerated() {
            let lat = FITParser.semicirclesToDegrees(record.positionLat ?? FITParser.invalidCoordinate)
            let lon = FITParser.semicirclesToDegrees(record.positionLong ?? FITParser.invalidCoordinate)
            guard GeoDistance.isValidCoordinate(lat: lat, lon: lon) else {
                continue
            }

            let altitude = decodeAltitude(record: record)
            let speed = decodeSpeed(record: record)

            let heartRate: Double?
            if let hr = record.heartRate, hr != FITParser.invalidUint8 {
                heartRate = Double(hr)
            } else {
                heartRate = nil
            }

            let cadence: Double?
            if let cad = record.cadence, cad != FITParser.invalidUint8 {
                cadence = Double(cad)
            } else {
                cadence = nil
            }

            let timestamp = resolvedTimestamps[index]
            let distance = record.distance.flatMap { value -> Double? in
                value == FITParser.invalidUint32 ? nil : FITParser.scaledDistanceToMeters(value)
            } ?? .nan

            let point = RoutePoint(
                timestamp: timestamp,
                latitude: lat,
                longitude: lon,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: timestamp.timeIntervalSince(startDate),
                speedMetersPerSecond: speed,
                heartRateBPM: heartRate,
                cadence: cadence
            )
            routePoints.append(point)
        }

        return RoutePointSanitizer.normalize(
            routePoints,
            distancePolicy: .useSuppliedDistancesPerSegment
        )
    }

    // MARK: - Session Selection

    /// Select the appropriate session from the decoded FIT file.
    private static func selectSession(from decodedFile: FITDecodedFile) throws -> SessionSelection {
        if decodedFile.sessions.isEmpty {
            return .legacyFallback
        }

        // Determine which sessions (by index) have GPS data in records
        var sessionsWithRecordGPS = Set<Int>()

        for record in decodedFile.records {
            guard let lat = record.positionLat, let lon = record.positionLong else { continue }
            guard lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate else { continue }
            guard let timestamp = record.timestamp else { continue }

            // Find which session(s) this record belongs to
            for (sessionIndex, session) in decodedFile.sessions.enumerated() {
            guard let sessionStart = sessionStartTime(for: session) else { continue }

                // Check if record is within the session timeframe
                if let sessionEnd = session.timestamp {
                    guard timestamp >= sessionStart && timestamp <= sessionEnd else { continue }
                } else {
                    guard timestamp >= sessionStart else { continue }
                }

                sessionsWithRecordGPS.insert(sessionIndex)
            }
        }

        // Find GPS-bearing sessions (either by start coords or by records with GPS)
        var gpsSessions: [(index: Int, session: FITSessionMessage, hasGPS: Bool)] = []

        for (index, session) in decodedFile.sessions.enumerated() {
            // A session has GPS if it has valid start coordinates
            let hasValidCoordinates: Bool
            if let lat = session.startPositionLat,
               let lon = session.startPositionLong {
                hasValidCoordinates = lat != FITParser.invalidCoordinate
                    && lon != FITParser.invalidCoordinate
            } else {
                hasValidCoordinates = false
            }

            // Or if it has records with GPS data
            let hasRecordGPS = hasValidCoordinates || sessionsWithRecordGPS.contains(index)

            gpsSessions.append((index: index, session: session, hasGPS: hasRecordGPS))
        }

        // Filter to GPS-bearing running sessions
        let gpsRunningSessions = gpsSessions.filter { entry in
            guard entry.hasGPS else { return false }
            guard let sport = entry.session.sport else { return true } // Unknown sport treated as running
            guard let sportType = FITSport(rawValue: sport) else { return true }
            return sportType.isRunning
        }

        // Filter to any GPS-bearing sessions
        let anyGPSSessions = gpsSessions.filter { $0.hasGPS }

        if gpsRunningSessions.count == 1 {
            // Exactly one GPS-bearing running session - select it
            return .selected(gpsRunningSessions[0].session, index: gpsRunningSessions[0].index)
        } else if gpsRunningSessions.count > 1 {
            // Multiple GPS-bearing running sessions - ambiguous
            throw WorkoutImportError.parsingError(
                "This FIT file contains \(gpsRunningSessions.count) runs. Only single-run files are supported."
            )
        } else if anyGPSSessions.isEmpty {
            // No GPS sessions at all - try legacy fallback
            return .legacyFallback
        } else {
            // Check if all sessions are non-running
            let hasNonRunningSessions = gpsSessions.contains { entry in
                guard entry.hasGPS, let sport = entry.session.sport else { return false }
                guard let sportType = FITSport(rawValue: sport) else { return false }
                return !sportType.isRunning
            }

            if hasNonRunningSessions {
                // All sessions are non-running
                let sportNames = gpsSessions.compactMap { entry -> String? in
                    guard entry.hasGPS, let sport = entry.session.sport else { return nil }
                    return FITSport(rawValue: sport).map { String(describing: $0) } ?? "unknown"
                }
                throw WorkoutImportError.parsingError(
                    "This FIT file contains a \(sportNames.joined(separator: ", ")) activity. "
                        + "Only running workouts are supported."
                )
            }

            return .legacyFallback
        }
    }

    /// Filter records to those within the session timeframe.
    private static func filterRecords(
        _ records: [FITRecordMessage],
        for session: FITSessionMessage,
        totalSessionCount: Int
    ) throws -> [FITRecordMessage] {
        guard let sessionStart = sessionStartTime(for: session) else {
            guard totalSessionCount == 1 else {
                throw WorkoutImportError.parsingError(
                    "Could not match GPS data to runs in this FIT file"
                )
            }
            return records
        }

        // A timestamp is required to associate a record with a selected session.
        // Unattributed records must not contaminate a multi-session import.
        return records.filter { record in
            guard let recordTimestamp = record.timestamp else { return false }
            if recordTimestamp < sessionStart { return false }
            if let sessionEnd = session.timestamp, recordTimestamp > sessionEnd { return false }
            return true
        }
    }

    /// Keep only timestamped events that can belong to the selected session.
    private static func filterEvents(
        _ events: [FITEventMessage],
        for session: FITSessionMessage,
        totalSessionCount: Int
    ) throws -> [FITEventMessage] {
        guard let sessionStart = sessionStartTime(for: session) else {
            guard totalSessionCount == 1 else {
                throw WorkoutImportError.parsingError(
                    "Could not match timing data to runs in this FIT file"
                )
            }
            return events
        }

        return events.filter { event in
            guard let timestamp = event.timestamp else { return false }
            if timestamp < sessionStart { return false }
            if let sessionEnd = session.timestamp, timestamp > sessionEnd { return false }
            return true
        }
    }

    /// FIT session messages normally include `start_time`; when they do not,
    /// derive it from the end timestamp and profile-scaled total elapsed time.
    /// Returning nil keeps multi-session imports fail-safe rather than merging
    /// records that cannot be attributed to one session.
    private static func sessionStartTime(for session: FITSessionMessage) -> UInt32? {
        if let startTime = session.startTime {
            return startTime
        }
        guard let endTime = session.timestamp,
              let totalElapsedMilliseconds = session.totalElapsedTime
        else {
            return nil
        }

        let elapsedSeconds = totalElapsedMilliseconds / 1_000
        guard elapsedSeconds <= endTime else { return nil }
        return endTime - elapsedSeconds
    }

    // MARK: - Route Segmentation from Timer Events

    /// A route segment defined by timer start/stop events.
    struct RouteSegment: Sendable {
        let startIndex: Int
        let endIndex: Int   // inclusive
    }

    /// Build route segments from timer events.
    ///
    /// Timer events define pause/resume boundaries:
    /// - start/resume: begins a new segment
    /// - stop/stopAll: ends the current segment
    private static func buildSegments(
        events: [FITEventMessage],
        records: [FITRecordMessage]
    ) -> [RouteSegment] {
        // Sort events by timestamp
        let timerEvents = events.filter { $0.timerEventType != nil }
            .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }

        guard !timerEvents.isEmpty else { return [] }

        guard !records.isEmpty else { return [] }

        var segments: [RouteSegment] = []
        var segmentStartIndex: Int?

        for event in timerEvents {
            guard let eventType = event.timerEventType,
                  let timestamp = event.timestamp else { continue }

            switch eventType {
            case .start:
                // Consecutive starts do not create empty or overlapping segments.
                guard segmentStartIndex == nil else { continue }
                segmentStartIndex = firstRecordIndex(
                    atOrAfter: timestamp,
                    in: records
                )

            case .stop, .stopAll:
                // Some devices omit the initial start event. Preserve records up
                // to the first stop as the continuous fallback segment.
                let startIdx = segmentStartIndex ?? (segments.isEmpty ? 0 : nil)
                if let startIdx,
                   let endIdx = lastRecordIndex(
                        atOrBefore: timestamp,
                        in: records,
                        startingAt: startIdx
                   ),
                   startIdx <= endIdx {
                    segments.append(RouteSegment(
                        startIndex: startIdx,
                        endIndex: endIdx
                    ))
                }
                segmentStartIndex = nil

            default:
                break
            }
        }

        // Close any open segment
        if let startIdx = segmentStartIndex {
            segments.append(RouteSegment(
                startIndex: startIdx,
                endIndex: records.count - 1
            ))
        }

        return segments
    }

    /// Find the first record at or after an event timestamp.
    private static func firstRecordIndex(
        atOrAfter timestamp: UInt32,
        in records: [FITRecordMessage]
    ) -> Int? {
        for i in records.indices {
            if let recordTs = records[i].timestamp, recordTs >= timestamp {
                return i
            }
        }
        return nil
    }

    /// Find the last record at or before an event timestamp in the active range.
    private static func lastRecordIndex(
        atOrBefore timestamp: UInt32,
        in records: [FITRecordMessage],
        startingAt startIndex: Int
    ) -> Int? {
        var result: Int?
        for i in startIndex..<records.count {
            guard let recordTimestamp = records[i].timestamp else { continue }
            if recordTimestamp > timestamp { break }
            result = i
        }
        return result
    }

    // MARK: - Record Decoding with Segmentation

    /// Decode records into RoutePoints with segment awareness.
    private static func decodeRecordsToRoutePoints(
        records: [FITRecordMessage],
        segments: [RouteSegment],
        usesTimerSegmentation: Bool
    ) throws -> [RoutePoint] {
        let validRecords = records.enumerated().compactMap { index, record -> (record: FITRecordMessage, segmentIndex: Int)? in
            guard let lat = record.positionLat, let lon = record.positionLong else {
                return nil
            }
            guard lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate else {
                return nil
            }

            let segmentIndex = segments.firstIndex {
                index >= $0.startIndex && index <= $0.endIndex
            }
            if usesTimerSegmentation, segmentIndex == nil {
                // Records between a stop and subsequent start belong to the pause.
                return nil
            }
            return (record, segmentIndex ?? 0)
        }

        guard !validRecords.isEmpty else { return [] }

        let resolvedTimestamps = RouteTimestampResolver.resolve(
            validRecords.map { entry in
                let record = entry.record
                guard let timestamp = record.timestamp, timestamp != FITParser.invalidUint32 else {
                    return nil
                }
                return FITParser.timestampToDate(timestamp)
            }
        )
        guard let resolvedTimestamps, let startDate = resolvedTimestamps.first else {
            return []
        }

        var routePoints: [RoutePoint] = []
        routePoints.reserveCapacity(validRecords.count)

        for (index, entry) in validRecords.enumerated() {
            let record = entry.record
            let lat = FITParser.semicirclesToDegrees(record.positionLat ?? FITParser.invalidCoordinate)
            let lon = FITParser.semicirclesToDegrees(record.positionLong ?? FITParser.invalidCoordinate)
            guard GeoDistance.isValidCoordinate(lat: lat, lon: lon) else {
                continue
            }

            let altitude = decodeAltitude(record: record)
            let speed = decodeSpeed(record: record)

            let heartRate: Double?
            if let hr = record.heartRate, hr != FITParser.invalidUint8 {
                heartRate = Double(hr)
            } else {
                heartRate = nil
            }

            let cadence: Double?
            if let cad = record.cadence, cad != FITParser.invalidUint8 {
                cadence = Double(cad)
            } else {
                cadence = nil
            }

            let timestamp = resolvedTimestamps[index]
            let distance = record.distance.flatMap { value -> Double? in
                value == FITParser.invalidUint32 ? nil : FITParser.scaledDistanceToMeters(value)
            } ?? .nan

            let point = RoutePoint(
                timestamp: timestamp,
                latitude: lat,
                longitude: lon,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: timestamp.timeIntervalSince(startDate),
                speedMetersPerSecond: speed,
                heartRateBPM: heartRate,
                cadence: cadence,
                routeSegmentIndex: entry.segmentIndex
            )
            routePoints.append(point)
        }

        return RoutePointSanitizer.normalize(
            routePoints,
            distancePolicy: .useSuppliedDistancesPerSegment
        )
    }

    // MARK: - Enhanced Metric Decoding

    /// Decode altitude from a record, preferring enhanced over legacy.
    private static func decodeAltitude(record: FITRecordMessage) -> Double? {
        // Enhanced altitude (UInt32, scale 5, offset 500)
        if let enhanced = record.enhancedAltitude,
           enhanced != FITParser.invalidUint32 {
            return FITParser.enhancedAltitudeToMeters(enhanced)
        }
        // Legacy altitude (UInt16, scale 5, offset 500)
        if let alt = record.altitude,
           alt != FITParser.invalidUint16 {
            return FITParser.scaledAltitudeToMeters(alt)
        }
        return nil
    }

    /// Decode speed from a record, preferring enhanced over legacy.
    private static func decodeSpeed(record: FITRecordMessage) -> Double? {
        // Enhanced speed (UInt32, scale 1000)
        if let enhanced = record.enhancedSpeed,
           enhanced != FITParser.invalidUint32 {
            return FITParser.enhancedSpeedToMPS(enhanced)
        }
        // Legacy speed (UInt16, scale 1000)
        if let speed = record.speed,
           speed != FITParser.invalidUint16 {
            return FITParser.scaledSpeedToMPS(speed)
        }
        return nil
    }
}
