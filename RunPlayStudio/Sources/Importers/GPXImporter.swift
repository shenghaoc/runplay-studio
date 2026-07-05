import Foundation
import CoreLocation

/// Imports workouts from GPX (GPS Exchange Format) files.
///
/// Supports basic GPX with trackpoints containing:
/// - latitude/longitude (required)
/// - elevation (optional)
/// - time (optional)
/// - heart rate via extensions (optional)
struct GPXImporter: WorkoutImporting {
    var supportedExtensions: [String] { ["gpx"] }

    func importWorkout(from url: URL) throws -> RunWorkout {
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

        var routePoints: [RoutePoint] = []
        var cumulativeDistance: Double = 0
        let startDate = rawPoints.first?.time ?? Date()

        for (index, raw) in rawPoints.enumerated() {
            let elapsed = raw.time?.timeIntervalSince(startDate) ?? Double(index)

            if index > 0 {
                let prev = rawPoints[index - 1]
                let from = CLLocation(latitude: prev.lat, longitude: prev.lon)
                let to = CLLocation(latitude: raw.lat, longitude: raw.lon)
                cumulativeDistance += from.distance(from: to)
            }

            let speed: Double? = nil
            let pace: Double? = nil

            let point = RoutePoint(
                timestamp: raw.time ?? startDate.addingTimeInterval(elapsed),
                latitude: raw.lat,
                longitude: raw.lon,
                altitudeMeters: raw.ele,
                distanceFromStartMeters: cumulativeDistance,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: speed,
                paceSecondsPerKilometer: pace,
                heartRateBPM: raw.hr,
                cadence: raw.cad
            )
            routePoints.append(point)
        }

        let metadata = WorkoutMetadata(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            activityType: "running",
            startDate: rawPoints.first?.time,
            endDate: rawPoints.last?.time
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
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: Date?
    var hr: Double?
    var cad: Double?
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

    init(xml: String) {
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
