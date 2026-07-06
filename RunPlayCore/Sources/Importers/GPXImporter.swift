import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports workouts from GPX (GPS Exchange Format) files.
///
/// Supports basic GPX with trackpoints containing:
/// - latitude/longitude (required)
/// - elevation (optional)
/// - time (optional)
/// - heart rate via extensions (optional)
public struct GPXImporter: WorkoutImporting {
    public init() {}
    public var supportedExtensions: [String] { ["gpx"] }

    public func importWorkout(from url: URL) throws -> RunWorkout {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }

        let data = try Data(contentsOf: url)
        guard let xml = String(data: data, encoding: .utf8) else {
            throw WorkoutImportError.invalidFormat("Could not read file as UTF-8")
        }

        return try parseGPX(xml, sourceURL: url)
    }

    // MARK: - Private

    private func parseGPX(_ xml: String, sourceURL: URL) throws -> RunWorkout {
        let parser = GPXXMLParser(xml: xml)
        let rawPoints = try parser.parse()

        guard !rawPoints.isEmpty else {
            throw WorkoutImportError.missingData("No trackpoints found in GPX file")
        }

        let validRawPoints = rawPoints.filter {
            GeoDistance.isValidCoordinate(lat: $0.lat, lon: $0.lon)
        }

        guard !validRawPoints.isEmpty else {
            throw WorkoutImportError.missingData("No valid coordinates found in GPX file")
        }

        // Require at least some timestamps for meaningful pace/duration analysis.
        // Missing timestamps between known points are interpolated below.
        guard let timestamps = RouteTimestampResolver.resolve(validRawPoints.map(\.time)),
              let startDate = timestamps.first else {
            throw WorkoutImportError.missingData("GPX file has no timestamps; cannot compute pace or duration")
        }

        var routePoints: [RoutePoint] = []

        for (raw, timestamp) in zip(validRawPoints, timestamps) {
            let point = RoutePoint(
                timestamp: timestamp,
                latitude: raw.lat,
                longitude: raw.lon,
                altitudeMeters: raw.ele,
                distanceFromStartMeters: 0,
                elapsedSeconds: timestamp.timeIntervalSince(startDate),
                heartRateBPM: raw.hr,
                cadence: raw.cad
            )
            routePoints.append(point)
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

private struct RawGPXPoint {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var time: Date?
    public var hr: Double?
    public var cad: Double?
}

private class GPXXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var points: [RawGPXPoint] = []
    private var currentElement: String = ""
    private var currentText: String = ""
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var currentHR: Double?
    private var currentCad: Double?
    private var inTrackpoint = false
    private var inExtensions = false

    public init(xml: String) {
        self.xml = xml
    }

    func parse() throws -> [RawGPXPoint] {
        guard let data = xml.data(using: .utf8) else {
            throw WorkoutImportError.invalidFormat("Could not encode XML as UTF-8")
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            throw WorkoutImportError.parsingError("XML parsing failed")
        }

        return points
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

        if elementName == "trkpt" || elementName == "wpt" {
            inTrackpoint = true
            currentLat = attributes["lat"].flatMap(Double.init)
            currentLon = attributes["lon"].flatMap(Double.init)
            currentEle = nil
            currentTime = nil
            currentHR = nil
            currentCad = nil
        }

        if elementName == "extensions" {
            inExtensions = true
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

        if inTrackpoint {
            switch elementName {
            case "ele":
                currentEle = Double(text)
            case "time":
                currentTime = parseISO8601(text)
            case "hr", "gpxtpx:hr":
                currentHR = Double(text)
            case "cad", "gpxtpx:cad":
                currentCad = Double(text)
            case "trkpt", "wpt":
                if let lat = currentLat, let lon = currentLon {
                    points.append(RawGPXPoint(
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

        if elementName == "extensions" {
            inExtensions = false
        }
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
    }
}
