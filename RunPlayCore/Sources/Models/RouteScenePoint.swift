import Foundation

/// A route point projected into 3D local meter-space coordinates for scene rendering.
public struct RouteScenePoint: Identifiable {
    public let id: UUID
    public var xMeters: Double
    public var yMeters: Double
    public var zMeters: Double
    public var sourceIndex: Int
    public var distanceFromStartMeters: Double
    public var elapsedSeconds: Double
    public var paceSecondsPerKilometer: Double?
    public var heartRateBPM: Double?

    public init(
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
