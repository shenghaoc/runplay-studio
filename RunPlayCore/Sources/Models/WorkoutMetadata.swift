import Foundation

/// Optional metadata about a running workout.
public struct WorkoutMetadata: Codable, Hashable, Sendable {
    public var name: String?
    public var notes: String?
    public var activityType: String
    public var startDate: Date?
    public var endDate: Date?
    public var deviceName: String?

    public init(
        name: String? = nil,
        notes: String? = nil,
        activityType: String = "running",
        startDate: Date? = nil,
        endDate: Date? = nil,
        deviceName: String? = nil
    ) {
        self.name = name
        self.notes = notes
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.deviceName = deviceName
    }
}
