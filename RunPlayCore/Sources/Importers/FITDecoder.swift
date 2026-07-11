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
        case selected(FITSessionMessage)
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

        switch selection {
        case .selected(let session):
            // Filter records to those within the session timeframe
            records = filterRecords(decodedFile.records, for: session)
            // Build segments from timer events
            segments = buildSegments(
                events: decodedFile.events,
                records: records
            )
        case .legacyFallback:
            records = decodedFile.records
            segments = []
        }

        return try decodeRecordsToRoutePoints(
            records: records,
            segments: segments
        )
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

        let hasCompleteDistanceSeries = validRecords.allSatisfy { record in
            guard let distance = record.distance else { return false }
            return distance != FITParser.invalidUint32
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
            } ?? 0

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
            distancePolicy: hasCompleteDistanceSeries ? .useSuppliedDistancesWhenValid : .computeFromCoordinates
        )
    }

    // MARK: - Session Selection

    /// Select the appropriate session from the decoded FIT file.
    private static func selectSession(from decodedFile: FITDecodedFile) throws -> SessionSelection {
        if decodedFile.sessions.isEmpty {
            return .legacyFallback
        }

        // Find GPS-bearing sessions
        var gpsSessions: [(session: FITSessionMessage, hasGPS: Bool)] = []

        for session in decodedFile.sessions {
            // A session has GPS if it has valid start coordinates
            let hasValidCoordinates: Bool
            if let lat = session.startPositionLat,
               let lon = session.startPositionLong {
                hasValidCoordinates = lat != FITParser.invalidCoordinate
                    && lon != FITParser.invalidCoordinate
            } else {
                hasValidCoordinates = false
            }
            gpsSessions.append((session: session, hasGPS: hasValidCoordinates))
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
            return .selected(gpsRunningSessions[0].session)
        } else if gpsRunningSessions.count > 1 {
            // Multiple GPS-bearing running sessions - ambiguous
            throw WorkoutImportError.parsingError(
                "FIT file contains \(gpsRunningSessions.count) GPS-bearing running sessions. Cannot determine which to import."
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
                    "FIT file contains non-running activity: \(sportNames.joined(separator: ", "))"
                )
            }

            return .legacyFallback
        }
    }

    /// Filter records to those within the session timeframe.
    private static func filterRecords(
        _ records: [FITRecordMessage],
        for session: FITSessionMessage
    ) -> [FITRecordMessage] {
        // If session has no start time, return all records
        guard let sessionStart = session.startTime else {
            return records
        }

        // Filter records that are at or after the session start time
        // and at or before the session end time (if available)
        return records.filter { record in
            guard let recordTimestamp = record.timestamp else { return true }
            if recordTimestamp < sessionStart { return false }
            if let sessionEnd = session.timestamp, recordTimestamp > sessionEnd { return false }
            return true
        }
    }

    // MARK: - Route Segmentation from Timer Events

    /// A route segment defined by timer start/stop events.
    struct RouteSegment: Sendable {
        let startIndex: Int
        let endIndex: Int   // inclusive
        let startTimestamp: UInt32
        let endTimestamp: UInt32?
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

        // Build timestamp-to-record-index mapping
        var timestampToIndex: [UInt32: Int] = [:]
        for (index, record) in records.enumerated() {
            if let ts = record.timestamp {
                timestampToIndex[ts] = index
            }
        }

        var segments: [RouteSegment] = []
        var segmentStartIndex: Int?
        var segmentStartTimestamp: UInt32?

        for event in timerEvents {
            guard let eventType = event.timerEventType,
                  let timestamp = event.timestamp else { continue }

            switch eventType {
            case .start:
                if let startIdx = segmentStartIndex {
                    // End previous segment at this point
                    let endIdx = findRecordIndex(
                        forTimestamp: timestamp,
                        in: records,
                        startIndex: startIdx
                    )
                    segments.append(RouteSegment(
                        startIndex: startIdx,
                        endIndex: endIdx ?? records.count - 1,
                        startTimestamp: segmentStartTimestamp ?? 0,
                        endTimestamp: timestamp
                    ))
                }
                segmentStartIndex = findRecordIndex(
                    forTimestamp: timestamp,
                    in: records,
                    startIndex: segmentStartIndex ?? 0
                ) ?? segmentStartIndex
                segmentStartTimestamp = timestamp

            case .stop, .stopAll:
                if let startIdx = segmentStartIndex {
                    let endIdx = findRecordIndex(
                        forTimestamp: timestamp,
                        in: records,
                        startIndex: startIdx
                    ) ?? records.count - 1
                    segments.append(RouteSegment(
                        startIndex: startIdx,
                        endIndex: endIdx,
                        startTimestamp: segmentStartTimestamp ?? 0,
                        endTimestamp: timestamp
                    ))
                    segmentStartIndex = nil
                    segmentStartTimestamp = nil
                }

            default:
                break
            }
        }

        // Close any open segment
        if let startIdx = segmentStartIndex {
            segments.append(RouteSegment(
                startIndex: startIdx,
                endIndex: records.count - 1,
                startTimestamp: segmentStartTimestamp ?? 0,
                endTimestamp: nil
            ))
        }

        return segments
    }

    /// Find the record index for a given timestamp.
    private static func findRecordIndex(
        forTimestamp timestamp: UInt32,
        in records: [FITRecordMessage],
        startIndex: Int
    ) -> Int? {
        for i in startIndex..<records.count {
            if let recordTs = records[i].timestamp, recordTs >= timestamp {
                return i
            }
        }
        return nil
    }

    // MARK: - Record Decoding with Segmentation

    /// Decode records into RoutePoints with segment awareness.
    private static func decodeRecordsToRoutePoints(
        records: [FITRecordMessage],
        segments: [RouteSegment]
    ) throws -> [RoutePoint] {
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

        let hasCompleteDistanceSeries = validRecords.allSatisfy { record in
            guard let distance = record.distance else { return false }
            return distance != FITParser.invalidUint32
        }

        // Map segments to valid record indices
        let segmentMap = buildSegmentMap(
            segments: segments,
            validRecords: validRecords
        )

        var routePoints: [RoutePoint] = []
        routePoints.reserveCapacity(validRecords.count)

        var currentSegmentIndex = 0

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

            // Track segment transitions
            if let segIdx = segmentMap[index], segIdx != currentSegmentIndex {
                currentSegmentIndex = segIdx
            }

            let timestamp = resolvedTimestamps[index]
            let rawDistance = record.distance.flatMap { value -> Double? in
                value == FITParser.invalidUint32 ? nil : FITParser.scaledDistanceToMeters(value)
            } ?? 0

            // For segmented routes, don't add geographic distance across pauses
            let distance: Double
            if !segments.isEmpty {
                distance = rawDistance
            } else {
                distance = rawDistance
            }

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
            distancePolicy: hasCompleteDistanceSeries ? .useSuppliedDistancesWhenValid : .computeFromCoordinates
        )
    }

    /// Build a mapping from valid record index to segment index.
    private static func buildSegmentMap(
        segments: [RouteSegment],
        validRecords: [FITRecordMessage]
    ) -> [Int: Int] {
        guard !segments.isEmpty else { return [:] }

        var map: [Int: Int] = [:]
        for (segIdx, segment) in segments.enumerated() {
            for i in segment.startIndex...min(segment.endIndex, validRecords.count - 1) {
                map[i] = segIdx
            }
        }
        return map
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
