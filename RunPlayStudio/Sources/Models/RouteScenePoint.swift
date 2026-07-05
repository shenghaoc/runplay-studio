import Foundation

/// A route point projected into 3D local meter-space coordinates for scene rendering.
struct RouteScenePoint: Identifiable {
    let id: UUID
    var xMeters: Double
    var yMeters: Double
    var zMeters: Double
    var sourceIndex: Int
    var distanceFromStartMeters: Double
    var elapsedSeconds: Double
    var paceSecondsPerKilometer: Double?
    var heartRateBPM: Double?

    init(
        id: UUID = UUID(),
        xMeters: Double,
        yMeters: Double,
        zMeters: Double,
        sourceIndex: Int,
        distanceFromStartMeters: Double,
        elapsedSeconds: Double,
        paceSecondsPerKilometer: Double? = nil,
        heartRateBPM: Double? = nil
    ) {
        self.id = id
        self.xMeters = xMeters
        self.yMeters = yMeters
        self.zMeters = zMeters
        self.sourceIndex = sourceIndex
        self.distanceFromStartMeters = distanceFromStartMeters
        self.elapsedSeconds = elapsedSeconds
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.heartRateBPM = heartRateBPM
    }
}
