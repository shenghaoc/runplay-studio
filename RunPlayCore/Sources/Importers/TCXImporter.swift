import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports workouts from TCX (Training Center XML) files.
///
/// Supports TCX structure:
/// - TrainingCenterDatabase > Activities > Activity > Lap > Track > Trackpoint
///
/// Recorded-lap policy:
/// - Each `<Lap>` becomes a `RecordedLap` with source summary fields.
/// - A lap boundary alone never creates a route discontinuity.
/// - Multiple `<Track>` elements use `TCXRouteContinuityResolver` to decide
///   whether recording paused or remained continuous.
/// - Route distance stays monotonic; per-lap distance resets are retained only
///   in source-reported metrics.
public struct TCXImporter: WorkoutImporting, @unchecked Sendable {
    public init() {}
    public var supportedExtensions: [String] { ["tcx"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        try validateLocalFile(url)
        let data = try readBoundedSourceData(at: url)
        return try importWorkout(
            data: data,
            suggestedName: url.deletingPathExtension().lastPathComponent
        )
    }

    public func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
        try WorkoutImportResourceLimits.validateSourceByteCount(input.data.count)
        return try importWorkout(
            data: input.data,
            suggestedName: input.suggestedName.isEmpty
                ? "Imported Run"
                : (input.suggestedName as NSString).deletingPathExtension
        )
    }

    /// Entry point for raw Data (URL and in-memory paths share this).
    func importWorkout(data: Data, sourceURL: URL) throws -> RunWorkout {
        try importWorkout(
            data: data,
            suggestedName: sourceURL.deletingPathExtension().lastPathComponent
        )
    }

    func importWorkout(
        data: Data,
        suggestedName: String,
        maxRoutePointCount: Int = WorkoutImportResourceLimits.maxRoutePointCount
    ) throws -> RunWorkout {
        let rawActivities = try parseTCXData(data, maxRoutePointCount: maxRoutePointCount)

        guard !rawActivities.isEmpty else {
            throw WorkoutImportError.missingData("No activities found in TCX file")
        }

        // Select the activity with GPS data.
        let gpsActivities = rawActivities.filter { activity in
            activity.laps.contains { lap in
                lap.tracks.contains { track in
                    track.points.contains { tp in
                        GeoDistance.isValidCoordinate(lat: tp.latitude, lon: tp.longitude)
                    }
                }
            }
        }

        if gpsActivities.isEmpty {
            throw WorkoutImportError.missingData("No GPS route data with valid coordinates found")
        }

        if gpsActivities.count > 1 {
            throw WorkoutImportError.invalidFormat("TCX file contains multiple GPS activities; only single-activity files are supported")
        }

        let activity = gpsActivities[0]

        // Authoritative check: the limit applies to the selected activity's
        // trackpoints. The parser also aborts mid-stream (see TCXXMLParser) so
        // an oversized activity is not fully materialized first; this repeats
        // the comparison against the activity actually chosen.
        let selectedTrackpointCount = activity.laps.reduce(into: 0) { count, lap in
            for track in lap.tracks { count += track.points.count }
        }
        if selectedTrackpointCount > maxRoutePointCount {
            throw WorkoutResourceLimitError.routePointLimitExceeded(
                count: selectedTrackpointCount,
                limit: maxRoutePointCount
            )
        }

        let invalidCoordinatePointCount = activity.laps.reduce(into: 0) { count, lap in
            for track in lap.tracks {
                count += track.points.reduce(into: 0) { trackCount, point in
                    if !GeoDistance.isValidCoordinate(
                        lat: point.latitude,
                        lon: point.longitude
                    ) {
                        trackCount += 1
                    }
                }
            }
        }

        // Flatten tracks with deliberate continuity, not one segment per lap.
        let continuity = TCXRouteContinuityPolicy.runningDefault
        var routePoints: [RoutePoint] = []
        var globalIndex = 0
        var segmentIndex = 0
        var previousContinuityPoint: TCXRouteContinuityResolver.ContinuityPoint?
        var hasAnySuppliedDistance = false
        var allSuppliedDistancesValid = true

        // Collect provisional recorded-lap definitions while walking tracks.
        var provisionalLaps: [RecordedLap] = []
        // Track first/last timestamps per lap for boundary fallback.
        var lapPointRanges: [(firstGlobalIndex: Int, lastGlobalIndex: Int)] = []

        // Flatten all valid points first for timestamp resolution.
        struct FlatPoint {
            var raw: RawTCXTrackpoint
            var lapIndex: Int
            var isTrackStart: Bool
        }
        var flat: [FlatPoint] = []
        for (lapIdx, lap) in activity.laps.enumerated() {
            for track in lap.tracks {
                var isFirstInTrack = true
                for tp in track.points {
                    guard GeoDistance.isValidCoordinate(lat: tp.latitude, lon: tp.longitude) else {
                        continue
                    }
                    flat.append(FlatPoint(raw: tp, lapIndex: lapIdx, isTrackStart: isFirstInTrack))
                    isFirstInTrack = false
                }
            }
        }

        guard !flat.isEmpty else {
            throw WorkoutImportError.missingData("No GPS route data with valid coordinates found")
        }

        guard let timestamps = RouteTimestampResolver.resolve(flat.map(\.raw.time)),
              let startDate = timestamps.first else {
            throw WorkoutImportError.missingData("TCX file has no timestamps; cannot compute pace or duration")
        }

        // Per-track distance rebasing only — never mix per-lap resets into a
        // decreasing global series. Normalization later makes distance monotonic.
        var trackLocalDistances: [Double?] = Array(repeating: nil, count: flat.count)
        var trackStart = 0
        while trackStart < flat.count {
            var trackEnd = trackStart + 1
            while trackEnd < flat.count, !flat[trackEnd].isTrackStart {
                trackEnd += 1
            }
            let rebased = rebaseDistance(
                (trackStart..<trackEnd).map { flat[$0].raw.distanceMeters }
            )
            for (offset, value) in rebased.enumerated() {
                trackLocalDistances[trackStart + offset] = value
            }
            trackStart = trackEnd
        }

        var currentLapFirstIndex: [Int: Int] = [:]
        var currentLapLastIndex: [Int: Int] = [:]
        var continuousTrackDistanceOffset = 0.0

        for (index, item) in flat.enumerated() {
            let timestamp = timestamps[index]
            let continuityPoint = TCXRouteContinuityResolver.ContinuityPoint(
                latitude: item.raw.latitude,
                longitude: item.raw.longitude,
                timestamp: timestamp
            )

            if item.isTrackStart, index > 0 {
                let decision = TCXRouteContinuityResolver.decide(
                    previous: previousContinuityPoint,
                    next: continuityPoint,
                    policy: continuity
                )
                if decision == .discontinuous {
                    segmentIndex += 1
                    continuousTrackDistanceOffset = 0
                } else {
                    continuousTrackDistanceOffset = routePoints.last?.distanceFromStartMeters ?? 0
                }
            }

            if let d = item.raw.distanceMeters {
                hasAnySuppliedDistance = true
                if !d.isFinite || d < 0 {
                    allSuppliedDistancesValid = false
                }
            } else {
                allSuppliedDistancesValid = false
            }

            let elapsed = timestamp.timeIntervalSince(startDate)
            let dist = (trackLocalDistances[index] ?? 0) + continuousTrackDistanceOffset

            let point = RoutePoint(
                timestamp: timestamp,
                latitude: item.raw.latitude,
                longitude: item.raw.longitude,
                altitudeMeters: item.raw.altitudeMeters,
                distanceFromStartMeters: dist,
                elapsedSeconds: elapsed,
                heartRateBPM: item.raw.heartRateBPM.map { Double($0) },
                cadence: item.raw.cadence.map { Double($0) },
                routeSegmentIndex: segmentIndex
            )
            routePoints.append(point)
            previousContinuityPoint = continuityPoint

            if currentLapFirstIndex[item.lapIndex] == nil {
                currentLapFirstIndex[item.lapIndex] = globalIndex
            }
            currentLapLastIndex[item.lapIndex] = globalIndex
            globalIndex += 1
        }

        for lapIdx in activity.laps.indices {
            if let first = currentLapFirstIndex[lapIdx],
               let last = currentLapLastIndex[lapIdx] {
                lapPointRanges.append((first, last))
            } else {
                lapPointRanges.append((-1, -1))
            }
        }

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid coordinates found in TCX file")
        }

        // Build provisional recorded laps from TCX Lap metadata.
        for (lapIdx, lap) in activity.laps.enumerated() {
            let range = lapPointRanges[lapIdx]
            let startDateForLap: Date?
            if let start = lap.startTime {
                startDateForLap = start
            } else if range.firstGlobalIndex >= 0 {
                startDateForLap = routePoints[range.firstGlobalIndex].timestamp
            } else {
                startDateForLap = nil
            }

            let nextLapStart = activity.laps.indices.contains(lapIdx + 1)
                ? activity.laps[lapIdx + 1].startTime
                : nil
            let endDateForLap: Date?
            if let nextLapStart {
                endDateForLap = nextLapStart
            } else if let start = startDateForLap,
                      let total = lap.totalTimeSeconds,
                      total.isFinite,
                      total > 0 {
                endDateForLap = start.addingTimeInterval(total)
            } else if range.lastGlobalIndex >= 0 {
                endDateForLap = routePoints[range.lastGlobalIndex].timestamp
            } else {
                endDateForLap = nil
            }

            let trigger = RecordedLapTrigger.fromTCXTriggerMethod(lap.triggerMethod)
            let reported = RecordedLapReportedMetrics(
                elapsedSeconds: lap.totalTimeSeconds,
                timerSeconds: lap.totalTimeSeconds,
                distanceMeters: lap.distanceMeters,
                ascentMeters: nil,
                descentMeters: nil,
                averageHeartRateBPM: lap.averageHeartRateBPM.map { Double($0) },
                maximumHeartRateBPM: lap.maximumHeartRateBPM.map { Double($0) },
                averageCadence: lap.cadence.map { Double($0) },
                averageSpeedMetersPerSecond: nil,
                maximumSpeedMetersPerSecond: lap.maximumSpeed,
                calories: lap.calories.map { Double($0) },
                rawIntensityValue: lap.intensity,
                rawTriggerValue: lap.triggerMethod
            )

            provisionalLaps.append(.provisional(
                lapIndex: provisionalLaps.count + 1,
                source: .tcx,
                trigger: trigger,
                sourceStartDate: startDateForLap,
                sourceEndDate: endDateForLap,
                reportedMetrics: reported.isEmpty ? nil : reported
            ))
        }

        let hasCompleteSuppliedDistanceSeries = hasAnySuppliedDistance && allSuppliedDistancesValid

        // Build metadata
        let metadata = WorkoutMetadata(
            name: suggestedName,
            activityType: activity.sport ?? "running",
            startDate: activity.activityId ?? routePoints.first?.timestamp,
            endDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .tcx,
            routePoints: routePoints,
            recordedLaps: provisionalLaps
        )
        workout.sourceStructureVersion = RunWorkout.currentSourceStructureVersion

        let analyzer = WorkoutAnalyzer()
        try analyzer.normalizeAndAnalyze(
            &workout,
            distancePolicy: hasCompleteSuppliedDistanceSeries
                ? .useSuppliedDistancesWhenValid
                : .computeFromCoordinates,
            sourceInvalidCoordinatePointCount: invalidCoordinatePointCount
        )

        return workout
    }

    // MARK: - Distance Rebasing

    /// Rebase a per-track distance series so it starts from 0.
    ///
    /// If the series starts at a nonzero value, subtract that offset from all entries.
    /// Returns `nil` for entries where the input was `nil`.
    private func rebaseDistance(_ distances: [Double?]) -> [Double?] {
        guard let firstNonNil = distances.compactMap({ $0 }).first else {
            return distances
        }
        let offset = firstNonNil
        return distances.map { $0.map { $0 - offset } }
    }
}

// MARK: - TCX XML Parser

/// A parsed TCX activity with laps and tracks.
private struct RawTCXActivity {
    var sport: String?
    var activityId: Date?
    var laps: [RawTCXLap]
}

/// A lap containing summary fields and one or more tracks.
private struct RawTCXLap {
    var startTime: Date?
    var totalTimeSeconds: Double?
    var distanceMeters: Double?
    var maximumSpeed: Double?
    var calories: Int?
    var averageHeartRateBPM: Int?
    var maximumHeartRateBPM: Int?
    var cadence: Int?
    var intensity: String?
    var triggerMethod: String?
    var tracks: [RawTCXTrack]
}

/// A track containing ordered trackpoints.
private struct RawTCXTrack {
    var points: [RawTCXTrackpoint]
}

private struct RawTCXTrackpoint {
    var time: Date?
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var distanceMeters: Double?
    var heartRateBPM: Int?
    var cadence: Int?
}

/// TCX XML parser that preserves activity/lap/track hierarchy and lap summaries.
private class TCXXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var activities: [RawTCXActivity] = []

    // Hierarchy tracking
    private var inActivity = false
    private var inLap = false
    private var inTrack = false
    private var inTrackpoint = false
    private var inPosition = false
    private var inHeartRate = false
    private var inAverageHeartRate = false
    private var inMaximumHeartRate = false

    // Current activity state
    private var currentSport: String?
    private var currentActivityId: Date?

    // Current lap state
    private var currentLapTracks: [RawTCXTrack] = []
    private var currentActivityLaps: [RawTCXLap] = []
    private var currentLapStartTime: Date?
    private var currentLapTotalTime: Double?
    private var currentLapDistance: Double?
    private var currentLapMaxSpeed: Double?
    private var currentLapCalories: Int?
    private var currentLapAvgHR: Int?
    private var currentLapMaxHR: Int?
    private var currentLapCadence: Int?
    private var currentLapIntensity: String?
    private var currentLapTrigger: String?

    // Current track points accumulator
    private var currentTrackPoints: [RawTCXTrackpoint] = []

    // Running `<Trackpoint>` total for the activity being parsed, reset at each
    // `<Activity>`. Counting per activity rather than per document keeps a
    // large non-selected activity from rejecting a file whose selected activity
    // is within the limit. `importWorkout` repeats the check authoritatively
    // once the activity is chosen.
    private var activityTrackpointCount = 0
    private var limitError: WorkoutResourceLimitError?
    private let maxRoutePointCount: Int

    // Current trackpoint state
    private var currentTime: Date?
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentAlt: Double?
    private var currentDist: Double?
    private var currentHR: Int?
    private var currentCadence: Int?

    // Character accumulation
    private var currentText: String = ""

    init(data: Data, maxRoutePointCount: Int) {
        self.data = data
        self.maxRoutePointCount = maxRoutePointCount
    }

    func parse() throws -> [RawTCXActivity] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let parsed = parser.parse()
        if let limitError {
            throw limitError
        }
        guard parsed else {
            throw WorkoutImportError.parsingError("This TCX file could not be read. Try re-exporting it.")
        }

        return activities
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        currentText = ""
        let name = localName(elementName)

        switch name {
        case "Activity":
            inActivity = true
            currentSport = attributes["Sport"]?.lowercased()
            currentActivityId = nil
            currentActivityLaps = []
            activityTrackpointCount = 0
        case "Lap":
            inLap = true
            currentLapTracks = []
            currentLapStartTime = attributes["StartTime"].flatMap(parseISO8601)
            currentLapTotalTime = nil
            currentLapDistance = nil
            currentLapMaxSpeed = nil
            currentLapCalories = nil
            currentLapAvgHR = nil
            currentLapMaxHR = nil
            currentLapCadence = nil
            currentLapIntensity = nil
            currentLapTrigger = nil
        case "Track":
            inTrack = true
            currentTrackPoints = []
        case "Trackpoint":
            inTrackpoint = true
            currentTime = nil
            currentLat = nil
            currentLon = nil
            currentAlt = nil
            currentDist = nil
            currentHR = nil
            currentCadence = nil
        case "Position":
            inPosition = true
        case "HeartRateBpm":
            inHeartRate = true
        case "AverageHeartRateBpm":
            inAverageHeartRate = true
            inHeartRate = true
        case "MaximumHeartRateBpm":
            inMaximumHeartRate = true
            inHeartRate = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = localName(elementName)

        switch name {
        case "Id":
            if inActivity, !inLap, !inTrackpoint {
                currentActivityId = parseISO8601(text)
            }
        case "Time":
            if inTrackpoint {
                currentTime = parseISO8601(text)
            }
        case "LatitudeDegrees":
            if inPosition {
                currentLat = Double(text)
            }
        case "LongitudeDegrees":
            if inPosition {
                currentLon = Double(text)
            }
        case "AltitudeMeters":
            if inTrackpoint {
                currentAlt = Double(text)
            }
        case "DistanceMeters":
            if inTrackpoint {
                currentDist = Double(text)
            } else if inLap, !inTrack, !inTrackpoint {
                currentLapDistance = Double(text)
            }
        case "TotalTimeSeconds":
            if inLap, !inTrack, !inTrackpoint {
                currentLapTotalTime = Double(text)
            }
        case "MaximumSpeed":
            if inLap, !inTrack, !inTrackpoint {
                currentLapMaxSpeed = Double(text)
            }
        case "Calories":
            if inLap, !inTrack, !inTrackpoint {
                currentLapCalories = Int(text)
            }
        case "Value":
            if inHeartRate {
                if inTrackpoint {
                    currentHR = Int(text)
                } else if inAverageHeartRate {
                    currentLapAvgHR = Int(text)
                } else if inMaximumHeartRate {
                    currentLapMaxHR = Int(text)
                }
            }
        case "Cadence":
            if inTrackpoint {
                currentCadence = Int(text)
            } else if inLap, !inTrack {
                currentLapCadence = Int(text)
            }
        case "Intensity":
            if inLap, !inTrack, !inTrackpoint {
                currentLapIntensity = text
            }
        case "TriggerMethod":
            if inLap, !inTrack, !inTrackpoint {
                currentLapTrigger = text
            }
        case "HeartRateBpm":
            inHeartRate = false
        case "AverageHeartRateBpm":
            inAverageHeartRate = false
            inHeartRate = false
        case "MaximumHeartRateBpm":
            inMaximumHeartRate = false
            inHeartRate = false
        case "Position":
            inPosition = false
        case "Trackpoint":
            if inTrackpoint, let lat = currentLat, let lon = currentLon {
                activityTrackpointCount += 1
                if activityTrackpointCount > maxRoutePointCount {
                    limitError = .routePointLimitExceeded(
                        count: activityTrackpointCount,
                        limit: maxRoutePointCount
                    )
                    parser.abortParsing()
                    return
                }
                currentTrackPoints.append(RawTCXTrackpoint(
                    time: currentTime,
                    latitude: lat,
                    longitude: lon,
                    altitudeMeters: currentAlt,
                    distanceMeters: currentDist,
                    heartRateBPM: currentHR,
                    cadence: currentCadence
                ))
            }
            inTrackpoint = false
        case "Track":
            if inTrack {
                currentLapTracks.append(RawTCXTrack(points: currentTrackPoints))
                currentTrackPoints = []
                inTrack = false
            }
        case "Lap":
            if inLap {
                currentActivityLaps.append(RawTCXLap(
                    startTime: currentLapStartTime,
                    totalTimeSeconds: currentLapTotalTime,
                    distanceMeters: currentLapDistance,
                    maximumSpeed: currentLapMaxSpeed,
                    calories: currentLapCalories,
                    averageHeartRateBPM: currentLapAvgHR,
                    maximumHeartRateBPM: currentLapMaxHR,
                    cadence: currentLapCadence,
                    intensity: currentLapIntensity,
                    triggerMethod: currentLapTrigger,
                    tracks: currentLapTracks
                ))
                currentLapTracks = []
                inLap = false
            }
        case "Activity":
            if inActivity {
                activities.append(RawTCXActivity(
                    sport: currentSport,
                    activityId: currentActivityId,
                    laps: currentActivityLaps
                ))
                currentActivityLaps = []
                inActivity = false
            }
        default:
            break
        }
    }

    /// Strip optional namespace prefixes (`ns:Lap` → `Lap`).
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    // MARK: - Date Parsing

    nonisolated(unsafe) private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601StandardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Lock = NSLock()

    private func parseISO8601(_ string: String) -> Date? {
        Self.iso8601Lock.lock()
        defer { Self.iso8601Lock.unlock() }
        if string.contains(".") {
            return Self.iso8601FractionalFormatter.date(from: string) ?? Self.iso8601StandardFormatter.date(from: string)
        }
        return Self.iso8601StandardFormatter.date(from: string)
    }
}

// MARK: - Data-based parsing entry point

private func parseTCXData(
    _ data: Data,
    maxRoutePointCount: Int
) throws -> [RawTCXActivity] {
    let parser = TCXXMLParser(data: data, maxRoutePointCount: maxRoutePointCount)
    return try parser.parse()
}
