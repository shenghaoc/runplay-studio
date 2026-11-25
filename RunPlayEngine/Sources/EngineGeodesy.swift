#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package struct EngineLocalMeters: Equatable, Sendable {
    package let xMeters: Double
    package let zMeters: Double
}

package enum EngineGeodesy {
    package static let earthRadiusMeters = 6_371_000.0

    package static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && latitude >= -90.0 && latitude <= 90.0
            && longitude >= -180.0 && longitude <= 180.0
    }

    package static func distanceMeters(
        latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double
    ) -> Double {
        guard isValidCoordinate(latitude: latitude1, longitude: longitude1),
              isValidCoordinate(latitude: latitude2, longitude: longitude2) else {
            return 0.0
        }

        let deltaLatitudeRadians = degreesToRadians(latitude2 - latitude1)
        let deltaLongitudeRadians = degreesToRadians(longitude2 - longitude1)
        let latitude1Radians = degreesToRadians(latitude1)
        let latitude2Radians = degreesToRadians(latitude2)

        // Match Geodesy.cpp's operation order, without clamping antipodes.
        let halfDeltaLatitudeSine = sin(deltaLatitudeRadians / 2.0)
        let halfDeltaLongitudeSine = sin(deltaLongitudeRadians / 2.0)
        let latitudeCosineProduct = cos(latitude1Radians) * cos(latitude2Radians)
        let latitudinalTerm = halfDeltaLatitudeSine * halfDeltaLatitudeSine
        let longitudinalTerm = latitudeCosineProduct * halfDeltaLongitudeSine * halfDeltaLongitudeSine
        let a = latitudinalTerm + longitudinalTerm
        let c = 2.0 * atan2(a.squareRoot(), (1.0 - a).squareRoot())
        return earthRadiusMeters * c
    }

    package static func projectToLocalMeters(
        latitude: Double, longitude: Double, centerLatitude: Double, centerLongitude: Double
    ) -> EngineLocalMeters {
        let centerLatitudeRadians = degreesToRadians(centerLatitude)
        let latitudeSecondHarmonic = 559.82 * cos(2.0 * centerLatitudeRadians)
        let latitudeFourthHarmonic = 1.175 * cos(4.0 * centerLatitudeRadians)
        let metersPerDegreeLatitudeBase = 111132.92 - latitudeSecondHarmonic
        let metersPerDegreeLatitude = metersPerDegreeLatitudeBase + latitudeFourthHarmonic
        let longitudeFirstHarmonic = 111412.84 * cos(centerLatitudeRadians)
        let longitudeThirdHarmonic = 93.5 * cos(3.0 * centerLatitudeRadians)
        let metersPerDegreeLongitude = longitudeFirstHarmonic - longitudeThirdHarmonic

        // Preserve raw deltas and propagate non-finite values, as in C++.
        let xMeters = (longitude - centerLongitude) * metersPerDegreeLongitude
        let zMeters = (latitude - centerLatitude) * metersPerDegreeLatitude
        return EngineLocalMeters(xMeters: xMeters, zMeters: zMeters)
    }

    private static func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180.0
    }
}
