import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports workouts from TCX (Training Center XML) files.
///
/// Supports TCX structure:
/// - TrainingCenterDatabase > Activities > Activity > Lap > Track > Trackpoint
/// - Each `<Track>` starts a new `routeSegmentIndex`.
/// - Each `<Lap>` also starts a new segment index.
/// - Distance is rebased per-track to prevent cross-segment phantom distance.
/// - Multi-activity files: if exactly one activity has GPS data, it is imported;
///   if multiple activities have GPS data, an error is thrown.
public struct TCXImporter: WorkoutImporting, @unchecked Sendable {
    public init() {}
    public var supportedExtensions: [String] { ["tcx"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        try validateLocalFile(url)
        let data = try Data(contentsOf: url)
        return try importWorkout(data: data, sourceURL: url)
    }

    /// Internal entry point for testability with raw Data.
    func importWorkout(data: Data, sourceURL: URL) throws -> RunWorkout {
        let rawActivities = try parseTCXData(data)

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
            throw WorkoutImportError.missingData("No trackpoints with valid coordinates found")
        }

        if gpsActivities.count > 1 {
            throw WorkoutImportError.invalidFormat("TCX file contains multiple GPS activities; only single-activity files are supported")
        }

        let activity = gpsActivities[0]

        // Flatten all tracks from all laps, preserving segment boundaries.
        // Each (lap, track) pair becomes one segment.
        struct SegmentData {
            var points: [RawTCXTrackpoint]
        }
        var segments: [SegmentData] = []
        for lap in activity.laps {
            for track in lap.tracks {
                let validPoints = track.points.filter { tp in
                    GeoDistance.isValidCoordinate(lat: tp.latitude, lon: tp.longitude)
                }
                if !validPoints.isEmpty {
                    segments.append(SegmentData(points: validPoints))
                }
            }
        }

        guard !segments.isEmpty else {
            throw WorkoutImportError.missingData("No trackpoints with valid coordinates found")
        }

        // Flatten for timestamp resolution.
        let allValidPoints = segments.flatMap(\.points)

        // Resolve timestamps
        guard let timestamps = RouteTimestampResolver.resolve(allValidPoints.map(\.time)),
              let startDate = timestamps.first else {
            throw WorkoutImportError.missingData("TCX file has no timestamps; cannot compute pace or duration")
        }

        // Build route points with segment indexes.
        var routePoints: [RoutePoint] = []
        var globalIndex = 0
        var hasAnySuppliedDistance = false
        var allSuppliedDistancesValid = true

        for (segmentIdx, segment) in segments.enumerated() {
            // Rebase distance within this segment so it starts from 0.
            let rebasedDistance = rebaseDistance(segment.points.map(\.distanceMeters))

            // Check raw distance completeness before rebasing.
            for raw in segment.points {
                if let d = raw.distanceMeters {
                    hasAnySuppliedDistance = true
                    if !d.isFinite || d < 0 {
                        allSuppliedDistancesValid = false
                    }
                } else {
                    allSuppliedDistancesValid = false
                }
            }

            for (localIdx, raw) in segment.points.enumerated() {
                let timestamp = timestamps[globalIndex]
                globalIndex += 1

                let elapsed = timestamp.timeIntervalSince(startDate)
                let dist = localIdx < rebasedDistance.count ? (rebasedDistance[localIdx] ?? 0) : 0

                let point = RoutePoint(
                    timestamp: timestamp,
                    latitude: raw.latitude,
                    longitude: raw.longitude,
                    altitudeMeters: raw.altitudeMeters,
                    distanceFromStartMeters: dist,
                    elapsedSeconds: elapsed,
                    heartRateBPM: raw.heartRateBPM.map { Double($0) },
                    cadence: raw.cadence.map { Double($0) },
                    routeSegmentIndex: segmentIdx
                )
                routePoints.append(point)
            }
        }

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid coordinates found in TCX file")
        }

        let hasCompleteSuppliedDistanceSeries = hasAnySuppliedDistance && allSuppliedDistancesValid

        routePoints = RoutePointSanitizer.normalize(
            routePoints,
            distancePolicy: hasCompleteSuppliedDistanceSeries ? .useSuppliedDistancesWhenValid : .computeFromCoordinates
        )

        // Build metadata
        let metadata = WorkoutMetadata(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            activityType: activity.sport ?? "running",
            startDate: activity.activityId ?? routePoints.first?.timestamp,
            endDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .tcx,
            routePoints: routePoints
        )

        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

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

/// A lap containing one or more tracks.
private struct RawTCXLap {
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

/// TCX XML parser that preserves activity/lap/track hierarchy.
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

    // Current activity state
    private var currentSport: String?
    private var currentActivityId: Date?

    // Current lap tracks accumulator
    private var currentLapTracks: [RawTCXTrack] = []
    private var currentActivityLaps: [RawTCXLap] = []

    // Current track points accumulator
    private var currentTrackPoints: [RawTCXTrackpoint] = []

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

    // Error tracking
    private var parseError: String?

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> [RawTCXActivity] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let line = parser.lineNumber
            let col = parser.columnNumber
            if let error = parseError {
                throw WorkoutImportError.parsingError("TCX parsing failed at line \(line), column \(col): \(error)")
            }
            throw WorkoutImportError.parsingError("TCX parsing failed at line \(line), column \(col)")
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

        switch elementName {
        case "Activity":
            inActivity = true
            currentSport = attributes["Sport"]?.lowercased()
            currentActivityId = nil
            currentActivityLaps = []
        case "Lap":
            inLap = true
            currentLapTracks = []
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

        switch elementName {
        case "Id":
            if inActivity {
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
            }
        case "Value":
            if inHeartRate {
                currentHR = Int(text)
            }
        case "Cadence":
            if inTrackpoint {
                currentCadence = Int(text)
            }
        case "HeartRateBpm":
            inHeartRate = false
        case "Position":
            inPosition = false
        case "Trackpoint":
            if inTrackpoint, let lat = currentLat, let lon = currentLon {
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
                currentActivityLaps.append(RawTCXLap(tracks: currentLapTracks))
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

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }

    // MARK: - Date Parsing

    private let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso8601StandardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func parseISO8601(_ string: String) -> Date? {
        if string.contains(".") {
            return iso8601FractionalFormatter.date(from: string) ?? iso8601StandardFormatter.date(from: string)
        }
        return iso8601StandardFormatter.date(from: string)
    }
}

// MARK: - Data-based parsing entry point

private func parseTCXData(_ data: Data) throws -> [RawTCXActivity] {
    let parser = TCXXMLParser(data: data)
    return try parser.parse()
}
