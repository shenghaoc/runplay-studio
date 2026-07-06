import Foundation

/// A notable segment of a running route.
public struct SegmentHighlight: Identifiable, Codable, Hashable {
    public let id: UUID
    public var type: SegmentType
    public var title: String
    public var subtitle: String
    public var startDistanceMeters: Double
    public var endDistanceMeters: Double
    public var startElapsedSeconds: Double
    public var endElapsedSeconds: Double
    public var durationSeconds: Double
    public var distanceMeters: Double
    public var paceSecondsPerKilometer: Double?
    public var elevationDeltaMeters: Double?
    public var averageHeartRate: Double?
    public var sourcePointRange: Range<Int>
    public var displayPriority: Int

    public init(
        id: UUID = UUID(),
        type: SegmentType,
        title: String,
        subtitle: String,
        startDistanceMeters: Double,
        endDistanceMeters: Double,
        startElapsedSeconds: Double,
        endElapsedSeconds: Double,
        durationSeconds: Double,
        distanceMeters: Double,
        paceSecondsPerKilometer: Double? = nil,
        elevationDeltaMeters: Double? = nil,
        averageHeartRate: Double? = nil,
        sourcePointRange: Range<Int>,
        displayPriority: Int = 0
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
        self.startElapsedSeconds = startElapsedSeconds
        self.endElapsedSeconds = endElapsedSeconds
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.elevationDeltaMeters = elevationDeltaMeters
        self.averageHeartRate = averageHeartRate
        self.sourcePointRange = sourcePointRange
        self.displayPriority = displayPriority
    }

    public var formattedPace: String {
        guard let pace = paceSecondsPerKilometer, pace > 0, pace.isFinite else { return "--" }
        let mins = Int(pace) / 60
        let secs = Int(pace) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    public var formattedDuration: String {
        let mins = Int(durationSeconds) / 60
        let secs = Int(durationSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    public var formattedDistance: String {
        if distanceMeters >= 1000 {
            return String(format: "%.1f km", distanceMeters / 1000)
        }
        return String(format: "%.0f m", distanceMeters)
    }

    public var formattedElevation: String {
        guard let elev = elevationDeltaMeters else { return "" }
        let sign = elev >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", elev)) m"
    }
}

/// Types of notable route segments.
public enum SegmentType: String, Codable, Hashable, CaseIterable {
    case fastest400m
    case fastest1km
    case slowest1km
    case biggestClimb
    case biggestDescent
    case slowdown
    case custom

    public var displayName: String {
        switch self {
        case .fastest400m: return "Fastest 400m"
        case .fastest1km: return "Fastest Kilometer"
        case .slowest1km: return "Slowest Kilometer"
        case .biggestClimb: return "Biggest Climb"
        case .biggestDescent: return "Biggest Descent"
        case .slowdown: return "Slowdown"
        case .custom: return "Custom"
        }
    }

    public var icon: String {
        switch self {
        case .fastest400m: return "bolt.fill"
        case .fastest1km: return "hare.fill"
        case .slowest1km: return "tortoise.fill"
        case .biggestClimb: return "mountain.2.fill"
        case .biggestDescent: return "arrow.down.right.circle.fill"
        case .slowdown: return "chart.line.downtrend.xyaxis"
        case .custom: return "mappin.and.ellipse"
        }
    }

    public var color: String {
        switch self {
        case .fastest400m, .fastest1km: return "blue"
        case .slowest1km: return "red"
        case .biggestClimb: return "orange"
        case .biggestDescent: return "purple"
        case .slowdown: return "yellow"
        case .custom: return "gray"
        }
    }
}
