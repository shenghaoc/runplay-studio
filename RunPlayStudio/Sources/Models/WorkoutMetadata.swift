import Foundation

/// Optional metadata about a running workout.
struct WorkoutMetadata: Codable, Hashable {
    var name: String?
    var notes: String?
    var activityType: String
    var startDate: Date?
    var endDate: Date?
    var deviceName: String?

    init(
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
