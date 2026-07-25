import Foundation

/// Route points decoded from one FIT session, plus the diagnostics the
/// analyzer needs. Named rather than a tuple so the explicit decode-by-index
/// entry point can be public API.
public struct FITDecodedRouteResult: Sendable {
    public let routePoints: [RoutePoint]
    public let invalidCoordinatePointCount: Int

    public init(routePoints: [RoutePoint], invalidCoordinatePointCount: Int) {
        self.routePoints = routePoints
        self.invalidCoordinatePointCount = invalidCoordinatePointCount
    }
}

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
    ///
    /// Multi-session containers reach `FITSessionImportService` instead, which
    /// decodes each selected session by explicit index.
    public static func decode(decodedFile: FITDecodedFile) throws -> [RoutePoint] {
        RoutePointSanitizer.normalize(
            try decodeRaw(decodedFile: decodedFile),
            distancePolicy: .useSuppliedDistancesPerSegment
        )
    }

    /// Decode source fields and explicit timer-event segments without route
    /// quality normalization. FITImporter uses this so diagnostics are retained.
    static func decodeRaw(decodedFile: FITDecodedFile) throws -> [RoutePoint] {
        try decodeRawResult(decodedFile: decodedFile).routePoints
    }

    /// Apply the single-workout session selection policy, then decode by index.
    ///
    /// This is a thin wrapper: the selection policy and the decoding are two
    /// separate steps so batch import can skip the former without duplicating
    /// the latter.
    static func decodeRawResult(
        decodedFile: FITDecodedFile
    ) throws -> FITDecodedRouteResult {
        switch try selectSession(from: decodedFile) {
        case .selected(_, let sessionIndex):
            return try decodeRawResult(
                index: FITSessionMessageIndex.build(decodedFile: decodedFile),
                sessionIndex: sessionIndex
            )
        case .legacyFallback:
            return try decodeLegacyWholeFile(decodedFile: decodedFile)
        }
    }

    /// Decode every record with no session scoping and no timer segmentation.
    ///
    /// Reached when the selection policy finds no GPS-bearing session — either
    /// because the container has no session messages at all, or because none of
    /// its sessions carries GPS. Behaviour is unchanged from before the
    /// multi-session refactor.
    static func decodeLegacyWholeFile(
        decodedFile: FITDecodedFile
    ) throws -> FITDecodedRouteResult {
        try decodeRecordsToRoutePoints(
            records: decodedFile.records,
            segments: [],
            usesTimerSegmentation: false
        )
    }

    /// Explicit decode-by-index. Does not consult the selection policy and does
    /// not mutate any shared decoder state.
    ///
    /// Prefer the `index:` overload when decoding several sessions from one
    /// container: rebuilding the message index per session would reintroduce a
    /// records × sessions scan.
    public static func decodeRawResult(
        decodedFile: FITDecodedFile,
        sessionIndex: Int
    ) throws -> FITDecodedRouteResult {
        try decodeRawResult(
            index: FITSessionMessageIndex.build(decodedFile: decodedFile),
            sessionIndex: sessionIndex
        )
    }

    /// Explicit decode-by-index against a message index built once per container.
    public static func decodeRawResult(
        index: FITSessionMessageIndex,
        sessionIndex: Int
    ) throws -> FITDecodedRouteResult {
        guard index.mode != .legacyNoSessions else {
            return try decodeRecordsToRoutePoints(
                records: index.decodedFile.records,
                segments: [],
                usesTimerSegmentation: false
            )
        }
        guard index.decodedFile.sessions.indices.contains(sessionIndex) else {
            throw WorkoutImportError.parsingError(
                "FIT session \(sessionIndex + 1) is not present in this file"
            )
        }

        let records = index.records(for: sessionIndex)
        let events = index.events(for: sessionIndex)
        let segments = buildSegments(events: events, records: records)
        let usesTimerSegmentation = events.contains {
            $0.timerEventType != nil && FITParser.timestampIfValid($0.timestamp) != nil
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
                guard let timestamp = FITParser.timestampIfValid(record.timestamp) else {
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

        // Determine which sessions (by index) have GPS data in records.
        //
        // Sorting the GPS timestamps once and binary searching each session's
        // range keeps this at O(r log r + s log r). The previous nested scan
        // was O(records × sessions); the containment rule is unchanged, so a
        // record inside two overlapping sessions still counts for both.
        let gpsTimestamps = decodedFile.records
            .compactMap { record -> UInt32? in
                guard let lat = record.positionLat, let lon = record.positionLong else { return nil }
                guard lat != FITParser.invalidCoordinate,
                      lon != FITParser.invalidCoordinate
                else {
                    return nil
                }
                return FITParser.timestampIfValid(record.timestamp)
            }
            .sorted()

        var sessionsWithRecordGPS = Set<Int>()
        for (sessionIndex, session) in decodedFile.sessions.enumerated() {
            guard let sessionStart = FITSessionAttribution.resolveStart(of: session) else {
                continue
            }
            guard let candidate = firstTimestamp(atOrAfter: sessionStart, in: gpsTimestamps) else {
                continue
            }
            if let sessionEnd = FITParser.timestampIfValid(session.timestamp),
               candidate > sessionEnd {
                continue
            }
            sessionsWithRecordGPS.insert(sessionIndex)
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

        // Filter to GPS-bearing running sessions. Classification lives in
        // FITSportPolicy so scan and import can never disagree; an unknown or
        // missing sport is still treated as running.
        let gpsRunningSessions = gpsSessions.filter { entry in
            entry.hasGPS && FITSportPolicy.classify(session: entry.session).isImportable
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
                entry.hasGPS && FITSportPolicy.classify(session: entry.session) == .unsupported
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

    /// First timestamp at or after `lowerBound` in a sorted array.
    /// Keeps session GPS detection logarithmic rather than a nested scan.
    private static func firstTimestamp(
        atOrAfter lowerBound: UInt32,
        in sorted: [UInt32]
    ) -> UInt32? {
        var low = sorted.startIndex
        var high = sorted.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if sorted[mid] < lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < sorted.endIndex ? sorted[low] : nil
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
        let timerEvents = events.compactMap { event
            -> (eventType: FITTimerEventType, timestamp: UInt32)? in
            guard let eventType = event.timerEventType,
                  let timestamp = FITParser.timestampIfValid(event.timestamp)
            else {
                return nil
            }
            return (eventType, timestamp)
        }.sorted { $0.timestamp < $1.timestamp }

        guard !timerEvents.isEmpty else { return [] }

        guard !records.isEmpty else { return [] }

        var segments: [RouteSegment] = []
        var segmentStartIndex: Int?
        // Timer events and FIT records are chronological. Keep one advancing
        // record cursor so a file with many pause/resume events is still O(n)
        // after the O(e log e) event sort above.
        var recordCursor = records.startIndex
        var lastClosedBoundaryRecordTimestamp: UInt32?
        var lastClosedBoundaryRecordIndex: Int?

        for event in timerEvents {
            switch event.eventType {
            case .start:
                // Consecutive starts do not create empty or overlapping segments.
                guard segmentStartIndex == nil else { continue }
                if event.timestamp == lastClosedBoundaryRecordTimestamp,
                   let boundaryIndex = lastClosedBoundaryRecordIndex {
                    // A stop/resume at the same timestamp shares its boundary
                    // record. Retaining this O(1) anchor also keeps following
                    // untimestamped samples in the resumed segment.
                    segmentStartIndex = boundaryIndex
                } else {
                    segmentStartIndex = firstRecordIndex(
                        atOrAfter: event.timestamp,
                        in: records,
                        cursor: &recordCursor
                    )
                }

            case .stop, .stopAll:
                // Some devices omit the initial start event. Preserve records up
                // to the first stop as the continuous fallback segment.
                let startIdx = segmentStartIndex ?? (segments.isEmpty ? 0 : nil)
                if let startIdx,
                   let endIdx = lastRecordIndex(
                        atOrBefore: event.timestamp,
                        in: records,
                        startingAt: startIdx,
                        cursor: &recordCursor
                   ),
                   startIdx <= endIdx {
                    segments.append(RouteSegment(
                        startIndex: startIdx,
                        endIndex: endIdx
                    ))
                    lastClosedBoundaryRecordTimestamp = FITParser.timestampIfValid(
                        records[endIdx].timestamp
                    )
                    lastClosedBoundaryRecordIndex = endIdx
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
        in records: [FITRecordMessage],
        cursor: inout Int
    ) -> Int? {
        while cursor < records.endIndex {
            guard let recordTimestamp = FITParser.timestampIfValid(records[cursor].timestamp) else {
                cursor += 1
                continue
            }
            if recordTimestamp >= timestamp { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Find the last record at or before an event timestamp in the active range.
    private static func lastRecordIndex(
        atOrBefore timestamp: UInt32,
        in records: [FITRecordMessage],
        startingAt startIndex: Int,
        cursor: inout Int
    ) -> Int? {
        cursor = max(cursor, startIndex)
        var result: Int?
        if startIndex < cursor,
           let startTimestamp = FITParser.timestampIfValid(records[startIndex].timestamp),
           startTimestamp <= timestamp {
            result = startIndex
        }
        while cursor < records.endIndex {
            guard let recordTimestamp = FITParser.timestampIfValid(records[cursor].timestamp) else {
                cursor += 1
                continue
            }
            if recordTimestamp > timestamp { break }
            result = cursor
            cursor += 1
        }
        return result
    }

    // MARK: - Record Decoding with Segmentation

    /// Decode records into RoutePoints with segment awareness.
    private static func decodeRecordsToRoutePoints(
        records: [FITRecordMessage],
        segments: [RouteSegment],
        usesTimerSegmentation: Bool
    ) throws -> FITDecodedRouteResult {
        var validRecords: [(record: FITRecordMessage, segmentIndex: Int)] = []
        validRecords.reserveCapacity(records.count)
        var invalidCoordinatePointCount = 0
        var segmentCursor = segments.startIndex

        for (index, record) in records.enumerated() {
            guard let lat = record.positionLat, let lon = record.positionLong else {
                invalidCoordinatePointCount += 1
                continue
            }
            guard lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate else {
                invalidCoordinatePointCount += 1
                continue
            }

            while segmentCursor < segments.endIndex,
                  index > segments[segmentCursor].endIndex {
                segmentCursor += 1
            }
            let segmentIndex: Int?
            if segmentCursor < segments.endIndex,
               index >= segments[segmentCursor].startIndex,
               index <= segments[segmentCursor].endIndex {
                segmentIndex = segmentCursor
            } else {
                segmentIndex = nil
            }
            if usesTimerSegmentation, segmentIndex == nil {
                // Records between a stop and subsequent start belong to the pause.
                continue
            }
            validRecords.append((record, segmentIndex ?? 0))
        }

        guard !validRecords.isEmpty else {
            return FITDecodedRouteResult(
                routePoints: [],
                invalidCoordinatePointCount: invalidCoordinatePointCount
            )
        }

        let resolvedTimestamps = RouteTimestampResolver.resolve(
            validRecords.map { entry in
                let record = entry.record
                guard let timestamp = FITParser.timestampIfValid(record.timestamp) else {
                    return nil
                }
                return FITParser.timestampToDate(timestamp)
            }
        )
        guard let resolvedTimestamps, let startDate = resolvedTimestamps.first else {
            return FITDecodedRouteResult(
                routePoints: [],
                invalidCoordinatePointCount: invalidCoordinatePointCount
            )
        }

        var routePoints: [RoutePoint] = []
        routePoints.reserveCapacity(validRecords.count)

        for (index, entry) in validRecords.enumerated() {
            let record = entry.record
            let lat = FITParser.semicirclesToDegrees(record.positionLat ?? FITParser.invalidCoordinate)
            let lon = FITParser.semicirclesToDegrees(record.positionLong ?? FITParser.invalidCoordinate)
            guard GeoDistance.isValidCoordinate(lat: lat, lon: lon) else {
                invalidCoordinatePointCount += 1
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

        return FITDecodedRouteResult(
            routePoints: routePoints,
            invalidCoordinatePointCount: invalidCoordinatePointCount
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
