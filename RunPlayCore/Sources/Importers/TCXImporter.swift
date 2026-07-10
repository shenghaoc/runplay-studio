import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports workouts from TCX (Training Center XML) files.
///
/// Supports common TCX structure:
/// - TrainingCenterDatabase > Activities > Activity > Lap > Track > Trackpoint
/// - Time, Position/LatitudeDegrees, Position/LongitudeDegrees
/// - AltitudeMeters, DistanceMeters, HeartRateBpm/Value, Cadence
public struct TCXImporter: WorkoutImporting {
    public init() {}
    public var supportedExtensions: [String] { ["tcx"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        guard url.isFileURL else {
            throw WorkoutImportError.invalidFormat("Only local file URLs are supported")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }

        let data = try Data(contentsOf: url)
        guard let xml = String(data: data, encoding: .utf8) else {
            throw WorkoutImportError.invalidFormat("Could not read file as UTF-8")
        }

        return try parseTCX(xml, sourceURL: url)
    }

    // MARK: - Private

    private func parseTCX(_ xml: String, sourceURL: URL) throws -> RunWorkout {
        let parser = TCXXMLParser(xml: xml)
        let rawResult = try parser.parse()

        guard !rawResult.trackpoints.isEmpty else {
            throw WorkoutImportError.missingData("No trackpoints found in TCX file")
        }

        // Filter to only trackpoints with valid coordinates
        let validPoints = rawResult.trackpoints.filter { tp in
            GeoDistance.isValidCoordinate(lat: tp.latitude, lon: tp.longitude)
        }

        guard !validPoints.isEmpty else {
            throw WorkoutImportError.missingData("No trackpoints with valid coordinates found")
        }

        // Require at least some timestamps for meaningful pace/duration analysis.
        // Missing timestamps between known points are interpolated below.
        guard let timestamps = RouteTimestampResolver.resolve(validPoints.map(\.time)),
              let startDate = timestamps.first else {
            throw WorkoutImportError.missingData("TCX file has no timestamps; cannot compute pace or duration")
        }

        let hasCompleteSuppliedDistanceSeries = validPoints.allSatisfy { point in
            guard let distance = point.distanceMeters else { return false }
            return distance.isFinite && distance >= 0
        }

        var routePoints: [RoutePoint] = []

        for (raw, timestamp) in zip(validPoints, timestamps) {
            let elapsed = timestamp.timeIntervalSince(startDate)

            let point = RoutePoint(
                timestamp: timestamp,
                latitude: raw.latitude,
                longitude: raw.longitude,
                altitudeMeters: raw.altitudeMeters,
                distanceFromStartMeters: raw.distanceMeters ?? 0,
                elapsedSeconds: elapsed,
                heartRateBPM: raw.heartRateBPM.map { Double($0) },
                cadence: raw.cadence.map { Double($0) }
            )
            routePoints.append(point)
        }

        routePoints = RoutePointSanitizer.normalize(
            routePoints,
            distancePolicy: hasCompleteSuppliedDistanceSeries ? .useSuppliedDistancesWhenValid : .computeFromCoordinates
        )

        // Build metadata
        let metadata = WorkoutMetadata(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            activityType: rawResult.sport ?? "running",
            startDate: rawResult.activityId ?? routePoints.first?.timestamp,
            endDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .tcx,
            routePoints: routePoints
        )

        // Run analysis
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        return workout
    }
}

// MARK: - TCX XML Parser

private struct RawTCXResult {
    var trackpoints: [RawTCXTrackpoint]
    var sport: String?
    var activityId: Date?
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

private class TCXXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var result = RawTCXResult(trackpoints: [])

    // Current parsing state
    private var currentElement: String = ""
    private var currentText: String = ""
    private var inTrackpoint = false
    private var inPosition = false
    private var inHeartRate = false
    private var inActivity = false

    // Current trackpoint being built
    private var currentTime: Date?
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentAlt: Double?
    private var currentDist: Double?
    private var currentHR: Int?
    private var currentCadence: Int?

    init(xml: String) {
        self.xml = xml
    }

    func parse() throws -> RawTCXResult {
        guard let data = xml.data(using: .utf8) else {
            throw WorkoutImportError.invalidFormat("Could not encode XML as UTF-8")
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw WorkoutImportError.parsingError("TCX XML parsing failed")
        }

        return result
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "Activity":
            inActivity = true
            if let sport = attributes["Sport"] {
                result.sport = sport.lowercased()
            }
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
                result.activityId = parseISO8601(text)
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
                result.trackpoints.append(RawTCXTrackpoint(
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
        case "Activity":
            inActivity = false
        default:
            break
        }
    }

    // Cached formatters for performance
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func parseISO8601(_ string: String) -> Date? {
        return Self.fractionalFormatter.date(from: string) ?? Self.standardFormatter.date(from: string)
    }
}
