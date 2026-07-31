import Foundation
@testable import RunPlayCore

// MARK: - Deterministic LCG

struct ProfilingLCG: Sendable {
    private var state: UInt64
    static let multiplier: UInt64 = 6_364_136_223_846_793_005
    static let increment: UInt64 = 1_442_695_040_888_963_407

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &* Self.multiplier &+ Self.increment
        return state
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func symmetric(_ magnitude: Double) -> Double {
        (unit() * 2 - 1) * magnitude
    }
}

// MARK: - Route builders

enum HotspotProfilingFixtures {
    static let baseDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    struct RouteOptions {
        var pointCount: Int
        var segmentCount: Int = 1
        var lapCount: Int = 0
        var stepMetres: Double = 10.0
        var includeHR: Bool = true
        var includeCadence: Bool = true
        var includeAltitude: Bool = true
        var includeSourceSpeed: Bool = true
        var stationaryWindows: Bool = false
        var altitudeHeavy: Bool = false
        var noisyElevation: Bool = false
        var pauseEvery: Int? = nil
        var seed: UInt64 = 42
        var baseLat: Double = 35.6812
        var baseLon: Double = 139.7671
        var name: String = "synthetic"
    }

    static func makeRoutePoints(options: RouteOptions) -> [RoutePoint] {
        var lcg = ProfilingLCG(seed: options.seed)
        let cosLat = cos(options.baseLat * .pi / 180.0)
        let metresPerDegLat = 111_320.0
        let metresPerDegLon = 111_320.0 * max(0.2, cosLat)
        var points: [RoutePoint] = []
        points.reserveCapacity(options.pointCount)
        var x: Double = 0
        var elapsed: Double = 0
        let pointsPerSegment = max(1, options.pointCount / max(1, options.segmentCount))

        for i in 0..<options.pointCount {
            let segment = min(options.segmentCount - 1, i / pointsPerSegment)
            let isStationary = options.stationaryWindows && (i % 40) >= 25
            let step = isStationary ? 0.05 : options.stepMetres
            let wiggle = lcg.symmetric(isStationary ? 0.2 : 2.5)
            let lat = options.baseLat + (Double(segment) * 0.0001) + wiggle / metresPerDegLat
            let lon = options.baseLon + (x + wiggle * 0.4) / metresPerDegLon

            let alt: Double?
            if options.includeAltitude {
                if options.altitudeHeavy {
                    alt = 100 + 250 * sin(Double(i) * 0.01) + (options.noisyElevation ? lcg.symmetric(8) : 0)
                } else if options.noisyElevation {
                    alt = 50 + lcg.symmetric(40) + (i % 97 == 0 ? 120 : 0)
                } else {
                    alt = 40 + 15 * sin(Double(i) * 0.02) + lcg.symmetric(2)
                }
            } else {
                alt = nil
            }

            let speed: Double? = options.includeSourceSpeed
                ? (isStationary ? 0.2 : 2.8 + lcg.symmetric(0.4))
                : nil
            let hr: Double? = options.includeHR
                ? (isStationary ? 95 + lcg.unit() * 10 : 130 + lcg.unit() * 35)
                : nil
            // Occasional HR gaps for C2-style fixtures.
            let hrOut: Double? = (options.includeHR && i % 17 == 0) ? nil : hr
            let cadence: Double? = options.includeCadence
                ? (isStationary ? 0 : 160 + lcg.unit() * 20)
                : nil

            let dt: Double
            if let pauseEvery = options.pauseEvery, i > 0, i % pauseEvery == 0 {
                dt = 45 // pause-like gap
            } else {
                dt = isStationary ? 1.0 : max(0.6, step / max(speed ?? 2.8, 0.5))
            }
            elapsed += dt

            points.append(RoutePoint(
                id: stableID(seed: options.seed, index: i),
                timestamp: baseDate.addingTimeInterval(elapsed),
                latitude: lat,
                longitude: lon,
                altitudeMeters: alt,
                distanceFromStartMeters: x,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: speed,
                paceSecondsPerKilometer: speed.flatMap { $0 > 0.1 ? 1000.0 / $0 : nil },
                heartRateBPM: hrOut,
                cadence: cadence,
                horizontalAccuracy: 5 + lcg.unit() * 3,
                routeSegmentIndex: segment
            ))
            x += step
        }
        return points
    }

    static func makeWorkout(options: RouteOptions) -> RunWorkout {
        let points = makeRoutePoints(options: options)
        var workout = RunWorkout(
            metadata: WorkoutMetadata(
                name: "\(options.name)-\(options.pointCount)",
                startDate: points.first?.timestamp
            ),
            routePoints: points
        )
        if options.lapCount > 0, !points.isEmpty {
            workout.recordedLaps = makeRecordedLaps(
                pointCount: points.count,
                lapCount: options.lapCount,
                points: points
            )
        }
        return workout
    }

    static func makeRecordedLaps(
        pointCount: Int,
        lapCount: Int,
        points: [RoutePoint]
    ) -> [RecordedLap] {
        guard lapCount > 0, pointCount > 1 else { return [] }
        let stride = max(1, pointCount / lapCount)
        var laps: [RecordedLap] = []
        laps.reserveCapacity(lapCount)
        for i in 0..<lapCount {
            let startIdx = min(pointCount - 2, i * stride)
            let endIdx = min(pointCount - 1, (i + 1) * stride)
            guard endIdx > startIdx else { continue }
            let start = points[startIdx]
            let end = points[endIdx]
            let distance = max(0, end.distanceFromStartMeters - start.distanceFromStartMeters)
            let elapsed = max(1, end.elapsedSeconds - start.elapsedSeconds)
            // Inject a few malformed candidates for A6 (negative reported elapsed).
            let malformed = i % 11 == 0
            let reported = RecordedLapReportedMetrics(
                elapsedSeconds: malformed ? -1 : elapsed,
                timerSeconds: elapsed,
                distanceMeters: distance,
                averageHeartRateBPM: start.heartRateBPM
            )
            laps.append(RecordedLap(
                lapIndex: i,
                source: .fit,
                trigger: .manual,
                sourceStartDate: start.timestamp,
                sourceEndDate: end.timestamp,
                startElapsedSeconds: start.elapsedSeconds,
                endElapsedSeconds: end.elapsedSeconds,
                startDistanceMeters: start.distanceFromStartMeters,
                endDistanceMeters: end.distanceFromStartMeters,
                elapsedSeconds: elapsed,
                activeSeconds: elapsed,
                movingSeconds: elapsed * 0.9,
                averageHeartRateBPM: start.heartRateBPM,
                reportedMetrics: reported
            ))
        }
        return laps
    }

    private static func stableID(seed: UInt64, index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var s = seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
        for i in 0..<8 {
            bytes[i] = UInt8((s >> (i * 8)) & 0xff)
        }
        s = s &* 0xBF58_476D_1CE4_E5B9 &+ UInt64(index)
        for i in 0..<8 {
            bytes[8 + i] = UInt8((s >> (i * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Family A fixtures

    static func a1() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 1_000,
            includeHR: true,
            includeCadence: true,
            includeAltitude: true,
            includeSourceSpeed: true,
            seed: 1_001,
            name: "A1-5k"
        ))
    }

    static func a2() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 100_000,
            segmentCount: 5,
            lapCount: 20,
            includeHR: true,
            includeCadence: true,
            includeAltitude: true,
            includeSourceSpeed: true,
            noisyElevation: true,
            pauseEvery: 5_000,
            seed: 1_002,
            name: "A2-dense"
        ))
    }

    static func a3() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 100_000,
            segmentCount: 1_000,
            seed: 1_003,
            name: "A3-many-seg"
        ))
    }

    static func a4() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 2_000,
            stationaryWindows: true,
            pauseEvery: 200,
            seed: 1_004,
            name: "A4-intermittent"
        ))
    }

    static func a5() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 10_000,
            altitudeHeavy: true,
            noisyElevation: true,
            seed: 1_005,
            name: "A5-altitude"
        ))
    }

    static func a6() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 5_000,
            lapCount: 80,
            seed: 1_006,
            name: "A6-laps"
        ))
    }

    static func a7() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 1_000_000,
            segmentCount: 1,
            lapCount: 10,
            seed: 1_007,
            name: "A7-product-limit"
        ))
    }

    // MARK: - Family B fixtures

    static func bPair(
        pointCount: Int,
        segments: Int = 1,
        seedPrimary: UInt64,
        seedComparison: UInt64,
        offsetLonDegrees: Double = 0,
        noise: Double = 1.5
    ) -> (primary: RunWorkout, comparison: RunWorkout) {
        let primary = makeWorkout(options: RouteOptions(
            pointCount: pointCount,
            segmentCount: segments,
            stepMetres: 10,
            seed: seedPrimary,
            name: "B-primary"
        ))
        let comparisonOpts = RouteOptions(
            pointCount: pointCount,
            segmentCount: segments,
            stepMetres: 10 + noise * 0.1,
            seed: seedComparison,
            baseLon: 139.7671 + offsetLonDegrees,
            name: "B-comparison"
        )
        let comparison = makeWorkout(options: comparisonOpts)
        return (primary, comparison)
    }

    static func b1() -> (RunWorkout, RunWorkout) {
        bPair(pointCount: 800, seedPrimary: 2_001, seedComparison: 2_002)
    }

    static func b2() -> (RunWorkout, RunWorkout) {
        bPair(pointCount: 2_000, seedPrimary: 2_011, seedComparison: 2_012)
    }

    static func b3() -> (RunWorkout, RunWorkout) {
        // Dense raw routes that adaptive sampling coarsens toward the 2k cap.
        // 20k points at 5 m/step keeps projected extent inside policy limits while
        // still exceeding the sample budget before adaptive coarsening.
        (
            makeWorkout(options: RouteOptions(
                pointCount: 20_000,
                stepMetres: 5,
                seed: 2_021,
                name: "B3-primary"
            )),
            makeWorkout(options: RouteOptions(
                pointCount: 20_000,
                stepMetres: 5,
                seed: 2_022,
                name: "B3-comparison"
            ))
        )
    }

    static func b4() -> (RunWorkout, RunWorkout) {
        bPair(pointCount: 2_000, segments: 50, seedPrimary: 2_031, seedComparison: 2_032)
    }

    static func b5() -> (RunWorkout, RunWorkout) {
        bPair(
            pointCount: 1_500,
            seedPrimary: 2_041,
            seedComparison: 2_042,
            offsetLonDegrees: 0.0003,
            noise: 4
        )
    }

    // MARK: - Family C fixtures

    static func c1() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 100_000,
            includeHR: false,
            includeCadence: false,
            includeAltitude: false,
            includeSourceSpeed: true,
            seed: 3_001,
            name: "C1-pace"
        ))
    }

    static func c2() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 100_000,
            includeHR: true,
            includeCadence: false,
            includeAltitude: false,
            includeSourceSpeed: true,
            seed: 3_002,
            name: "C2-hr-gaps"
        ))
    }

    static func c3() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 20_000,
            altitudeHeavy: true,
            seed: 3_003,
            name: "C3-elevation"
        ))
    }

    static func c4() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 100_000,
            segmentCount: 200,
            includeSourceSpeed: true,
            seed: 3_004,
            name: "C4-segments"
        ))
    }

    static func c5() -> RunWorkout {
        makeWorkout(options: RouteOptions(
            pointCount: 1_000_000,
            includeSourceSpeed: true,
            seed: 3_005,
            name: "C5-product-limit"
        ))
    }

    // MARK: - Import serializers

    static func jsonData(pointCount: Int, seed: UInt64, segments: Int = 1) -> Data {
        let workout = makeWorkout(options: RouteOptions(
            pointCount: pointCount,
            segmentCount: segments,
            lapCount: pointCount >= 1_000 ? 5 : 0,
            seed: seed,
            name: "json"
        ))
        // Hand-build ISO8601 JSON compatible with JSONWorkoutImporter.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var json = #"{"metadata":{"name":"json-\#(pointCount)","activityType":"running","startDate":"\#(formatter.string(from: workout.routePoints.first?.timestamp ?? baseDate))"},"routePoints":["#
        for (i, p) in workout.routePoints.enumerated() {
            if i > 0 { json += "," }
            let ts = formatter.string(from: p.timestamp)
            let alt = p.altitudeMeters.map { String($0) } ?? "null"
            let hr = p.heartRateBPM.map { String($0) } ?? "null"
            json += #"{"id":"\#(p.id.uuidString)","timestamp":"\#(ts)","latitude":\#(p.latitude),"longitude":\#(p.longitude),"altitudeMeters":\#(alt),"distanceFromStartMeters":\#(p.distanceFromStartMeters),"elapsedSeconds":\#(p.elapsedSeconds),"heartRateBPM":\#(hr),"routeSegmentIndex":\#(p.routeSegmentIndex)}"#
        }
        json += "]}"
        return Data(json.utf8)
    }

    static func gpxData(pointCount: Int, seed: UInt64, segments: Int = 1, partialTimestamps: Bool = false) -> Data {
        let points = makeRoutePoints(options: RouteOptions(
            pointCount: pointCount,
            segmentCount: segments,
            seed: seed,
            name: "gpx"
        ))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunPlayHotspotProfile">
          <trk><name>gpx-\(pointCount)</name>
        """
        let perSeg = max(1, pointCount / max(1, segments))
        var index = 0
        for seg in 0..<segments {
            xml += "<trkseg>\n"
            let end = min(points.count, (seg + 1) * perSeg)
            while index < end {
                let p = points[index]
                let time: String
                if partialTimestamps && index % 7 == 0 {
                    time = ""
                } else {
                    time = "<time>\(formatter.string(from: p.timestamp))</time>"
                }
                let ele = p.altitudeMeters.map { "<ele>\($0)</ele>" } ?? ""
                let hr = p.heartRateBPM.map {
                    "<extensions><gpxtpx:TrackPointExtension xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\"><gpxtpx:hr>\(Int($0))</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
                } ?? ""
                xml += #"<trkpt lat="\#(p.latitude)" lon="\#(p.longitude)">\#(ele)\#(time)\#(hr)</trkpt>"# + "\n"
                index += 1
            }
            xml += "</trkseg>\n"
        }
        xml += "</trk></gpx>"
        return Data(xml.utf8)
    }

    static func tcxData(pointCount: Int, seed: UInt64, lapCount: Int = 3, multiActivity: Bool = false) -> Data {
        let points = makeRoutePoints(options: RouteOptions(
            pointCount: pointCount,
            lapCount: lapCount,
            seed: seed,
            name: "tcx"
        ))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let start = formatter.string(from: points.first?.timestamp ?? baseDate)
        func activityXML(idSuffix: String, usePoints: [RoutePoint]) -> String {
            var body = """
            <Activity Sport="Running">
              <Id>\(start)-\(idSuffix)</Id>
            """
            let perLap = max(1, usePoints.count / max(1, lapCount))
            var idx = 0
            for lap in 0..<lapCount {
                let end = min(usePoints.count, (lap + 1) * perLap)
                let slice = Array(usePoints[idx..<end])
                idx = end
                let lapStart = formatter.string(from: slice.first?.timestamp ?? baseDate)
                let dist = (slice.last?.distanceFromStartMeters ?? 0) - (slice.first?.distanceFromStartMeters ?? 0)
                let elapsed = (slice.last?.elapsedSeconds ?? 0) - (slice.first?.elapsedSeconds ?? 0)
                body += """
                <Lap StartTime="\(lapStart)">
                  <TotalTimeSeconds>\(max(1, elapsed))</TotalTimeSeconds>
                  <DistanceMeters>\(max(0, dist))</DistanceMeters>
                  <Calories>100</Calories>
                  <Intensity>Active</Intensity>
                  <TriggerMethod>Manual</TriggerMethod>
                  <Track>
                """
                for p in slice {
                    let t = formatter.string(from: p.timestamp)
                    let alt = p.altitudeMeters.map { "<AltitudeMeters>\($0)</AltitudeMeters>" } ?? ""
                    let hr = p.heartRateBPM.map { "<HeartRateBpm><Value>\(Int($0))</Value></HeartRateBpm>" } ?? ""
                    let cad = p.cadence.map { "<Cadence>\(Int($0))</Cadence>" } ?? ""
                    body += """
                    <Trackpoint>
                      <Time>\(t)</Time>
                      <Position><LatitudeDegrees>\(p.latitude)</LatitudeDegrees><LongitudeDegrees>\(p.longitude)</LongitudeDegrees></Position>
                      \(alt)
                      <DistanceMeters>\(p.distanceFromStartMeters)</DistanceMeters>
                      \(hr)
                      \(cad)
                    </Trackpoint>
                    """
                }
                body += "</Track></Lap>"
            }
            body += "</Activity>"
            return body
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
        """
        xml += activityXML(idSuffix: "a", usePoints: points)
        if multiActivity {
            xml += activityXML(idSuffix: "b", usePoints: Array(points.prefix(min(20, points.count))))
        }
        xml += "</Activities></TrainingCenterDatabase>"
        return Data(xml.utf8)
    }

    // MARK: - Library query fixtures

    static func libraryEntries(count: Int, seed: UInt64 = 9_001) -> (
        entries: [WorkoutLibraryEntry],
        documents: [UUID: WorkoutLibrarySearchDocument]
    ) {
        var lcg = ProfilingLCG(seed: seed)
        var entries: [WorkoutLibraryEntry] = []
        entries.reserveCapacity(count)
        var documents: [UUID: WorkoutLibrarySearchDocument] = [:]
        let calendar = Calendar(identifier: .gregorian)
        for i in 0..<count {
            let id = stableID(seed: seed, index: i)
            let name = "Run \(i % 50) \(i)"
            let start = baseDate.addingTimeInterval(Double(i) * 3600)
            let distance = 3_000 + lcg.unit() * 15_000
            let elapsed = 900 + lcg.unit() * 4_000
            let pace = elapsed / (distance / 1000)
            let favorite = i % 11 == 0
            let source: WorkoutSource = i % 3 == 0 ? .gpx : (i % 3 == 1 ? .fit : .json)
            let entry = WorkoutLibraryEntry(
                id: id,
                manifestIndex: i,
                isFavorite: favorite,
                displayName: name,
                metadataName: name,
                notes: i % 5 == 0 ? "note-\(i)" : nil,
                activityType: "running",
                deviceName: i % 7 == 0 ? "Watch" : nil,
                source: source,
                importProvider: nil,
                originalFilename: "file-\(i).gpx",
                startDate: start,
                totalDistanceMeters: distance,
                activePaceSecondsPerKilometer: pace,
                totalElapsedSeconds: elapsed,
                hasHeartRate: i % 2 == 0,
                hasCorrectedElevation: i % 3 == 0,
                hasRecordedLaps: i % 4 == 0,
                nameNotesRevision: "r\(i)",
                tagIDs: [],
                tagNames: i % 9 == 0 ? ["tempo"] : [],
                tagRevision: ""
            )
            entries.append(entry)
            documents[id] = WorkoutLibrarySearchDocument.make(from: entry, calendar: calendar)
        }
        return (entries, documents)
    }
}
