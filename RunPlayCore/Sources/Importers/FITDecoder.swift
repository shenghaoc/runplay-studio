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
    /// Delegates distance normalization and timestamp ordering to `RoutePointSanitizer`.
    public static func decode(records: [FITRecordMessage]) -> [RoutePoint] {
        let validRecords = records.filter { record in
            guard let lat = record.positionLat, let lon = record.positionLong else {
                return false
            }
            return lat != FITParser.invalidCoordinate && lon != FITParser.invalidCoordinate
        }

        guard !validRecords.isEmpty else {
            return []
        }

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

            let altitude: Double?
            if let alt = record.enhancedAltitude, alt != FITParser.invalidUint16 {
                altitude = FITParser.scaledAltitudeToMeters(alt)
            } else if let alt = record.altitude, alt != FITParser.invalidUint16 {
                altitude = FITParser.scaledAltitudeToMeters(alt)
            } else {
                altitude = nil
            }

            let speed: Double?
            if let s = record.enhancedSpeed, s != FITParser.invalidUint16 {
                speed = FITParser.scaledSpeedToMPS(s)
            } else if let s = record.speed, s != FITParser.invalidUint16 {
                speed = FITParser.scaledSpeedToMPS(s)
            } else {
                speed = nil
            }

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
}
