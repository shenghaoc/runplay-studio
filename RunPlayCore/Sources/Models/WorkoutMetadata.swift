import Foundation

/// Optional metadata about a running workout.
public struct WorkoutMetadata: Codable, Hashable, Sendable {
    public var name: String?
    public var notes: String?
    public var activityType: String
    public var startDate: Date?
    public var endDate: Date?
    public var deviceName: String?
    /// UTC offset literally encoded in the source timestamps, in seconds east
    /// of Greenwich (`32_400` is UTC+9). `nil` when the format logged UTC
    /// instants only (FIT) or no offset could be read. Calendar features use
    /// this to place the run on its recorded local date.
    public var recordedUTCOffsetSeconds: Int?

    public init(
        name: String? = nil,
        notes: String? = nil,
        activityType: String = "running",
        startDate: Date? = nil,
        endDate: Date? = nil,
        deviceName: String? = nil,
        recordedUTCOffsetSeconds: Int? = nil
    ) {
        self.name = name
        self.notes = notes
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.deviceName = deviceName
        self.recordedUTCOffsetSeconds = recordedUTCOffsetSeconds
    }
}
