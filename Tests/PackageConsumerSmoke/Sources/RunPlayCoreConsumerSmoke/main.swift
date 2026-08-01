import Foundation
import RunPlayCore

// Representative external-consumer smoke test for the RunPlayCore public API,
// beyond a bare import. It exercises stable platform-neutral value APIs:
// geodesy, the route-point model, and Codable round-tripping.
//
// This is compile-and-run, not compile-only: the `precondition` calls below are
// real runtime assertions, and CI both builds this package and runs the binary.
// Building alone would type-check the API usage but never execute an assertion.

let distance = GeoDistance.distanceMeters(
    fromLat: 37.7749, lon: -122.4194,
    toLat: 37.8044, lon: -122.2712
)
precondition(distance > 0, "Haversine distance should be positive")

let projected = GeoDistance.latLonToMeters(
    lat: 37.7749, lon: -122.4194,
    centerLat: 37.7749, centerLon: -122.4194
)
precondition(abs(projected.x) < 0.001 && abs(projected.z) < 0.001,
             "center projection should be near the origin")

precondition(GeoDistance.isValidCoordinate(lat: 37.7749, lon: -122.4194))
precondition(!GeoDistance.isValidCoordinate(lat: 91.0, lon: 0.0))

let point = RoutePoint(
    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
    latitude: 37.7749,
    longitude: -122.4194,
    altitudeMeters: 12.0,
    distanceFromStartMeters: 0,
    elapsedSeconds: 0,
    speedMetersPerSecond: 3.2,
    paceSecondsPerKilometer: 312.5,
    heartRateBPM: 145
)
precondition(point.latitude == 37.7749)

// Codable round-trip through the public model surface.
let encoder = JSONEncoder()
let decoder = JSONDecoder()
if let data = try? encoder.encode(point),
   let roundTripped = try? decoder.decode(RoutePoint.self, from: data) {
    precondition(roundTripped.heartRateBPM == point.heartRateBPM)
} else {
    preconditionFailure("RoutePoint Codable round-trip failed")
}

print("RunPlayCore external package consumer compiled with representative API usage")
