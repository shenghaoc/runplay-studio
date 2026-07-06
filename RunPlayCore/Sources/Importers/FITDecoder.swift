import Foundation

/// Decodes FIT record messages into RoutePoints.
///
/// Handles coordinate conversion, scaling, and validation.
/// Uses platform-neutral `GeoDistance` instead of CoreLocation.
public struct FITDecoder {

    public init() {}

    /// Convert FIT record messages to RoutePoints.
    ///
    /// Filters out records without valid GPS coordinates.
    /// Handles distance normalization and timestamp ordering.
    public static func decode(records: [FITRecordMessage]) -> [RoutePoint] {
        // Filter to records with valid GPS coordinates
        let validRecords = records.filter { record in
            guard let lat = record.positionLat, let lon = record.positionLong else {
                return false
            }
            return lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate
        }

        guard !validRecords.isEmpty else {
            return []
        }

        var routePoints: [RoutePoint] = []
        var cumulativeDistance: Double = 0
        var lastTimestamp: UInt32?

        for (index, record) in validRecords.enumerated() {
            // Get timestamp
            let timestamp: Date
            if let ts = record.timestamp {
                timestamp = FITParser.timestampToDate(ts)

                // Ensure monotonic timestamps
                if let last = lastTimestamp, ts <= last {
                    continue // Skip non-monotonic
                }
                lastTimestamp = ts
            } else {
                // Generate timestamp from index
                timestamp = Date(timeIntervalSince1970: Double(index))
            }

            // Convert coordinates
            let lat = FITParser.semicirclesToDegrees(record.positionLat!)
            let lon = FITParser.semicirclesToDegrees(record.positionLong!)

            // Validate coordinates
            guard GeoDistance.isValidCoordinate(lat: lat, lon: lon) else {
                continue
            }

            // Get altitude
            let altitude: Double?
            if let alt = record.enhancedAltitude, alt != FITParser.invalidUint16 {
                altitude = FITParser.scaledAltitudeToMeters(alt)
            } else if let alt = record.altitude, alt != FITParser.invalidUint16 {
                altitude = FITParser.scaledAltitudeToMeters(alt)
            } else {
                altitude = nil
            }

            // Get distance
            if let dist = record.distance, dist != FITParser.invalidUint32 {
                let fitDistance = FITParser.scaledDistanceToMeters(dist)
                // Use FIT distance if it's valid and nondecreasing
                if fitDistance >= cumulativeDistance {
                    cumulativeDistance = fitDistance
                } else if index > 0 {
                    // Compute from coordinates
                    let prev = validRecords[index - 1]
                    let prevLat = FITParser.semicirclesToDegrees(prev.positionLat!)
                    let prevLon = FITParser.semicirclesToDegrees(prev.positionLong!)
                    cumulativeDistance += GeoDistance.distanceMeters(
                        fromLat: prevLat, lon: prevLon,
                        toLat: lat, lon: lon
                    )
                }
            } else if index > 0 {
                // Compute from coordinates
                let prev = validRecords[index - 1]
                let prevLat = FITParser.semicirclesToDegrees(prev.positionLat!)
                let prevLon = FITParser.semicirclesToDegrees(prev.positionLong!)
                cumulativeDistance += GeoDistance.distanceMeters(
                    fromLat: prevLat, lon: prevLon,
                    toLat: lat, lon: lon
                )
            }

            // Get speed
            let speed: Double?
            if let s = record.enhancedSpeed, s != FITParser.invalidUint16 {
                speed = FITParser.scaledSpeedToMPS(s)
            } else if let s = record.speed, s != FITParser.invalidUint16 {
                speed = FITParser.scaledSpeedToMPS(s)
            } else {
                speed = nil
            }

            // Get heart rate
            let heartRate: Double?
            if let hr = record.heartRate, hr != FITParser.invalidUint8 {
                heartRate = Double(hr)
            } else {
                heartRate = nil
            }

            // Get cadence
            let cadence: Double?
            if let cad = record.cadence, cad != FITParser.invalidUint8 {
                cadence = Double(cad)
            } else {
                cadence = nil
            }

            // Calculate elapsed time
            let elapsed: Double
            if let firstTimestamp = validRecords.first?.timestamp,
               let currentTimestamp = record.timestamp {
                elapsed = Double(currentTimestamp - firstTimestamp)
            } else {
                elapsed = Double(index)
            }

            let point = RoutePoint(
                timestamp: timestamp,
                latitude: lat,
                longitude: lon,
                altitudeMeters: altitude,
                distanceFromStartMeters: cumulativeDistance,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: speed,
                heartRateBPM: heartRate,
                cadence: cadence
            )
            routePoints.append(point)
        }

        return routePoints
    }
}
