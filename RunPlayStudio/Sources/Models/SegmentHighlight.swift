import Foundation

/// A notable segment of a running route.
struct SegmentHighlight: Identifiable, Codable, Hashable {
    let id: UUID
    var type: SegmentType
    var startIndex: Int
    var endIndex: Int
    var startDistanceMeters: Double
    var endDistanceMeters: Double
    var value: Double
    var label: String

    init(
        id: UUID = UUID(),
        type: SegmentType,
        startIndex: Int,
        endIndex: Int,
        startDistanceMeters: Double,
        endDistanceMeters: Double,
        value: Double,
        label: String
    ) {
        self.id = id
        self.type = type
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
        self.value = value
        self.label = label
    }
}

/// Types of notable route segments.
enum SegmentType: String, Codable, Hashable, CaseIterable {
    case fastestKilometer
    case fastestMile
    case steepestClimb
    case steepestDescent
    case slowestKilometer

    var displayName: String {
        switch self {
        case .fastestKilometer: return "Fastest Kilometer"
        case .fastestMile: return "Fastest Mile"
        case .steepestClimb: return "Steepest Climb"
        case .steepestDescent: return "Steepest Descent"
        case .slowestKilometer: return "Slowest Kilometer"
        }
    }
}
