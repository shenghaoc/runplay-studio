import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports workouts from GPX (GPS Exchange Format) files.
///
/// Supports GPX track data only (`<trk>` > `<trkseg>` > `<trkpt>`).
/// - `<wpt>` (waypoint) elements are ignored.
/// - `<rte>` / `<rtept>` (route) elements are not supported.
/// - Each `<trkseg>` starts a new `routeSegmentIndex`.
public struct GPXImporter: WorkoutImporting, @unchecked Sendable {
    public init() {}
    public var supportedExtensions: [String] { ["gpx"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        try validateLocalFile(url)
        let data = try Data(contentsOf: url)
        return try importWorkout(data: data, sourceURL: url)
    }

    /// Internal entry point for testability with raw Data.
    func importWorkout(data: Data, sourceURL: URL) throws -> RunWorkout {
        let rawSegments = try parseGPXData(data)

        let allRawPoints = rawSegments.flatMap(\.points)
        guard !allRawPoints.isEmpty else {
            throw WorkoutImportError.missingData("No GPS route data found in this GPX file")
        }

        // Build RoutePoints with segment indexes, preserving raw timestamps.
        var routePoints: [RoutePoint] = []
        var rawTimestamps: [Date?] = []
        var segmentIndex = 0

        for segment in rawSegments {
            guard !segment.points.isEmpty else {
                segmentIndex += 1
                continue
            }

            let validSegmentPoints = segment.points.filter {
                GeoDistance.isValidCoordinate(lat: $0.lat, lon: $0.lon)
            }
            guard !validSegmentPoints.isEmpty else {
                segmentIndex += 1
                continue
            }

            for raw in validSegmentPoints {
                let point = RoutePoint(
                    timestamp: Date.distantPast,
                    latitude: raw.lat,
                    longitude: raw.lon,
                    altitudeMeters: raw.ele,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0,
                    heartRateBPM: raw.hr,
                    cadence: raw.cad,
                    routeSegmentIndex: segmentIndex
                )
                routePoints.append(point)
                rawTimestamps.append(raw.time)
            }
            segmentIndex += 1
        }

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid coordinates found in GPX file")
        }

        // Resolve timestamps globally (segments may share a continuous timeline).
        guard let resolvedTimestamps = RouteTimestampResolver.resolve(rawTimestamps),
              let startDate = resolvedTimestamps.first else {
            throw WorkoutImportError.missingData("GPX file has no timestamps; cannot compute pace or duration")
        }

        // Apply resolved timestamps and compute elapsed.
        for i in routePoints.indices {
            routePoints[i].timestamp = resolvedTimestamps[i]
            routePoints[i].elapsedSeconds = resolvedTimestamps[i].timeIntervalSince(startDate)
        }

        routePoints = RoutePointSanitizer.normalize(routePoints)

        guard !routePoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid coordinates found in GPX file")
        }

        let metadata = WorkoutMetadata(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            activityType: "running",
            startDate: routePoints.first?.timestamp,
            endDate: routePoints.last?.timestamp
        )

        var workout = RunWorkout(
            metadata: metadata,
            source: .gpx,
            routePoints: routePoints
        )

        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        return workout
    }
}

// MARK: - GPX XML Parser

/// A single parsed trackpoint from GPX.
private struct RawGPXPoint {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: Date?
    var hr: Double?
    var cad: Double?
}

/// A track segment containing ordered trackpoints.
private struct RawGPXSegment {
    var points: [RawGPXPoint]
}

/// GPX XML parser.
///
/// Parses the GPX hierarchy: `gpx > trk > trkseg > trkpt`.
/// Uses `shouldProcessNamespaces = false` and strips prefixes from element
/// names so both `<hr>` and `<gpxtpx:hr>` match by local name.
private class GPXXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var segments: [RawGPXSegment] = []

    // Hierarchy tracking
    private var inTrackSegment = false
    private var inTrackpoint = false

    // Current trackpoint state
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var currentHR: Double?
    private var currentCad: Double?

    // Current segment points accumulator
    private var currentSegmentPoints: [RawGPXPoint] = []

    // Character accumulation
    private var currentText: String = ""

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> [RawGPXSegment] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw WorkoutImportError.parsingError("This GPX file could not be read. Try re-exporting it.")
        }

        return segments
    }

    /// Strip namespace prefix from element name.  `gpxtpx:hr` → `hr`.
    private func localName(_ elementName: String) -> String {
        if let idx = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...])
        }
        return elementName
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
        case "trkseg":
            inTrackSegment = true
            currentSegmentPoints = []
        case "trkpt":
            inTrackpoint = true
            currentLat = attributes["lat"].flatMap(Double.init)
            currentLon = attributes["lon"].flatMap(Double.init)
            currentEle = nil
            currentTime = nil
            currentHR = nil
            currentCad = nil
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

        if inTrackpoint {
            switch name {
            case "ele":
                currentEle = Double(text)
            case "time":
                currentTime = parseISO8601(text)
            case "hr":
                currentHR = Double(text)
            case "cad":
                currentCad = Double(text)
            case "trkpt":
                if let lat = currentLat, let lon = currentLon {
                    currentSegmentPoints.append(RawGPXPoint(
                        lat: lat,
                        lon: lon,
                        ele: currentEle,
                        time: currentTime,
                        hr: currentHR,
                        cad: currentCad
                    ))
                }
                inTrackpoint = false
            default:
                break
            }
        }

        switch name {
        case "trkseg":
            // Finalize segment — only if it contained trackpoints.
            if inTrackSegment {
                segments.append(RawGPXSegment(points: currentSegmentPoints))
                currentSegmentPoints = []
                inTrackSegment = false
            }
        default:
            break
        }
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

private func parseGPXData(_ data: Data) throws -> [RawGPXSegment] {
    let parser = GPXXMLParser(data: data)
    return try parser.parse()
}
