import Foundation

// MARK: - Decoded FIT Message Types

/// Decoded FIT file containing all parsed messages.
public struct FITDecodedFile: Sendable {
    public var fileID: FITFileIDMessage?
    public var deviceInfo: [FITDeviceInfoMessage]
    public var sessions: [FITSessionMessage]
    public var laps: [FITLapMessage]
    public var events: [FITEventMessage]
    public var records: [FITRecordMessage]
    public var activities: [FITActivityMessage]
    /// All supported standard messages in their original on-disk order.
    public var orderedMessages: [FITOrderedMessage]

    public init(
        fileID: FITFileIDMessage? = nil,
        deviceInfo: [FITDeviceInfoMessage] = [],
        sessions: [FITSessionMessage] = [],
        laps: [FITLapMessage] = [],
        events: [FITEventMessage] = [],
        records: [FITRecordMessage] = [],
        activities: [FITActivityMessage] = [],
        orderedMessages: [FITOrderedMessage] = []
    ) {
        self.fileID = fileID
        self.deviceInfo = deviceInfo
        self.sessions = sessions
        self.laps = laps
        self.events = events
        self.records = records
        self.activities = activities
        self.orderedMessages = orderedMessages
    }
}

/// A supported standard FIT message, retained in source order for consumers
/// that need to associate records, timer events, and summary metadata.
public enum FITOrderedMessage: Sendable {
    case fileID(FITFileIDMessage)
    case record(FITRecordMessage)
    case event(FITEventMessage)
    case lap(FITLapMessage)
    case session(FITSessionMessage)
    case activity(FITActivityMessage)
    case deviceInfo(FITDeviceInfoMessage)
}

// MARK: - File ID (Global Message 0)

public struct FITFileIDMessage: Sendable {
    public var type: UInt8?         // field 0: file type enum
    public var manufacturer: UInt16? // field 1
    public var product: UInt16?      // field 2
    public var serialNumber: UInt32? // field 3
    public var timeCreated: UInt32?  // field 4: FIT timestamp
    public var number: UInt16?       // field 5

    public init() {}
}

// MARK: - Record (Global Message 20)

public struct FITRecordMessage: Sendable {
    public var timestamp: UInt32?
    public var positionLat: Int32?      // semicircles
    public var positionLong: Int32?     // semicircles
    public var altitude: UInt16?        // scaled
    public var enhancedAltitude: UInt32?
    public var distance: UInt32?        // scaled
    public var speed: UInt16?           // scaled
    public var enhancedSpeed: UInt32?
    public var heartRate: UInt8?
    public var cadence: UInt8?
    public var temperature: Int8?

    public init() {}
}

// MARK: - Event (Global Message 21)

/// FIT timer event type values.
public enum FITTimerEventType: UInt8, Sendable {
    case start = 0
    case stop = 1
    case consecutiveDepreciated = 2
    case marker = 3
    case stopAll = 4
    case beginDepreciated = 5
    case endDepreciated = 6
    case endAllDepreciated = 7
    case stopDisable = 8
    case stopDisableAll = 9
}

public struct FITEventMessage: Sendable {
    public var timestamp: UInt32?
    public var event: UInt8?        // field 0: event type enum
    public var eventType: UInt8?    // field 1: event trigger type
    public var eventGroup: UInt8?   // field 2

    public init() {}

    /// Returns the timer event type if this is a timer event (event == 0).
    public var timerEventType: FITTimerEventType? {
        guard event == 0 else { return nil }
        return eventType.flatMap(FITTimerEventType.init)
    }
}

// MARK: - Lap (Global Message 19)

public struct FITLapMessage: Sendable {
    public var messageIndex: UInt16?
    public var timestamp: UInt32?
    public var startTime: UInt32?
    public var startPositionLat: Int32?
    public var startPositionLong: Int32?
    public var endPositionLat: Int32?
    public var endPositionLong: Int32?
    public var totalElapsedTime: UInt32?    // scaled 1000
    public var totalTimerTime: UInt32?      // scaled 1000
    public var totalDistance: UInt32?       // scaled 100
    public var totalCalories: UInt16?
    public var totalAscent: UInt16?
    public var totalDescent: UInt16?
    public var averageSpeed: UInt16?        // scaled 1000
    public var maximumSpeed: UInt16?        // scaled 1000
    /// FIT Profile enhanced_avg_speed (field 110), scaled 1000.
    public var enhancedAverageSpeed: UInt32?
    /// FIT Profile enhanced_max_speed (field 111), scaled 1000.
    public var enhancedMaximumSpeed: UInt32?
    public var averageHeartRate: UInt8?
    public var maximumHeartRate: UInt8?
    public var averageCadence: UInt8?
    public var event: UInt8?
    public var eventType: UInt8?
    public var eventGroup: UInt8?
    public var lapTrigger: UInt8?
    public var sport: UInt8?

    public init() {}
}

// MARK: - Session (Global Message 18)

public struct FITSessionMessage: Sendable {
    public var timestamp: UInt32?
    public var startTime: UInt32?
    public var startPositionLat: Int32?
    public var startPositionLong: Int32?
    public var sport: UInt8?            // field 5
    public var subSport: UInt8?         // field 6
    public var totalElapsedTime: UInt32?    // scaled 1000, field 7
    public var totalTimerTime: UInt32?      // scaled 1000, field 8
    public var totalDistance: UInt32?       // scaled 100, field 9
    public var totalAscent: UInt16?
    public var totalDescent: UInt16?
    public var averageSpeed: UInt16?        // scaled 1000
    public var maximumSpeed: UInt16?        // scaled 1000
    public var averageHeartRate: UInt8?
    public var maximumHeartRate: UInt8?
    public var averageCadence: UInt8?
    public var event: UInt8?
    public var eventType: UInt8?
    /// Index of the first lap message belonging to this session.
    public var firstLapIndex: UInt16?
    /// Number of lap messages belonging to this session.
    public var numberOfLaps: UInt16?
    public var eventGroup: UInt8?
    public var trigger: UInt8?
    public var necLong: Int32?          // field 29
    public var necLat: Int32?           // field 30
    public var swcLong: Int32?          // field 31
    public var swcLat: Int32?           // field 32

    public init() {}
}

// MARK: - Activity (Global Message 34)

public struct FITActivityMessage: Sendable {
    public var timestamp: UInt32?
    public var totalTimerTime: UInt32?  // scaled 1000
    public var localTimestamp: UInt32?
    public var numSessions: UInt16?
    public var type: UInt8?             // activity type
    public var event: UInt8?
    public var eventType: UInt8?
    public var eventGroup: UInt8?

    public init() {}
}

// MARK: - Device Info (Global Message 23)

public struct FITDeviceInfoMessage: Sendable {
    public var timestamp: UInt32?
    public var serialNumber: UInt32?
    public var manufacturer: UInt16?
    public var product: UInt16?
    public var softwareVersion: UInt16?     // scaled 100
    public var hardwareVersion: UInt8?
    public var deviceIndex: UInt8?
    public var deviceType: UInt8?
    public var productName: String?

    public init() {}
}

// MARK: - FIT Profile Constants

/// FIT global message numbers from the official profile.
public enum FITGlobalMessage: UInt16, Sendable {
    case fileID = 0
    case session = 18
    case lap = 19
    case record = 20
    case event = 21
    case deviceInfo = 23
    case activity = 34
}

/// FIT base type encoding values from the protocol spec.
public enum FITBaseType: UInt8, Sendable {
    case `enum` = 0
    case sint8 = 1
    case uint8 = 2
    case sint16 = 0x83
    case uint16 = 0x84
    case sint32 = 0x85
    case uint32 = 0x86
    case string = 0x07
    case float32 = 0x88
    case float64 = 0x89
    case uint8z = 0x0A
    case uint16z = 0x8B
    case uint32z = 0x8C
    case byte = 0x0D
    case sint64 = 0x8E
    case uint64 = 0x8F
    case uint64z = 0x90

    /// Number of bytes for a single element of this base type.
    public var byteSize: Int {
        switch self {
        case .enum, .sint8, .uint8, .uint8z, .byte: return 1
        case .sint16, .uint16, .uint16z: return 2
        case .sint32, .uint32, .uint32z, .float32: return 4
        case .sint64, .uint64, .uint64z, .float64: return 8
        case .string: return 1 // variable length
        }
    }

}

// MARK: - FIT Record Field Numbers

/// Known field numbers for record messages (global message 20).
public enum FITRecordField: UInt8 {
    case timestamp = 253
    case positionLat = 0
    case positionLong = 1
    case altitude = 2
    case heartRate = 3
    case cadence = 4
    case distance = 5
    case speed = 6
    case enhancedAltitude = 78
    case enhancedSpeed = 73
    case temperature = 13
}

/// Known field numbers for event messages (global message 21).
public enum FITEventField: UInt8 {
    case timestamp = 253
    case event = 0
    case eventType = 1
    case eventGroup = 2
}

/// Known field numbers for session messages (global message 18).
public enum FITSessionField: UInt8 {
    case timestamp = 253
    case startTime = 2
    case startPositionLat = 3
    case startPositionLong = 4
    case sport = 5
    case subSport = 6
    case totalElapsedTime = 7
    case totalTimerTime = 8
    case totalDistance = 9
    case totalAscent = 22
    case totalDescent = 23
    case averageSpeed = 14
    case maximumSpeed = 15
    case averageHeartRate = 16
    case maximumHeartRate = 17
    case averageCadence = 18
    case event = 0
    case eventType = 1
    case firstLapIndex = 25
    case numberOfLaps = 26
    case eventGroup = 27
    case trigger = 28
    case necLat = 29
    case necLong = 30
    case swcLat = 31
    case swcLong = 32
}

/// Known field numbers for lap messages (global message 19).
public enum FITLapField: UInt8 {
    case messageIndex = 254
    case timestamp = 253
    case startTime = 2
    case startPositionLat = 3
    case startPositionLong = 4
    case endPositionLat = 5
    case endPositionLong = 6
    case totalElapsedTime = 7
    case totalTimerTime = 8
    case totalDistance = 9
    case totalCalories = 11
    case totalAscent = 21
    case totalDescent = 22
    case averageSpeed = 13
    case maximumSpeed = 14
    case averageHeartRate = 15
    case maximumHeartRate = 16
    case averageCadence = 17
    case event = 0
    case eventType = 1
    case lapTrigger = 24
    case sport = 25
    case eventGroup = 26
    case enhancedAverageSpeed = 110
    case enhancedMaximumSpeed = 111
}

/// Known field numbers for file_id messages (global message 0).
public enum FITFileIDField: UInt8 {
    case type = 0
    case manufacturer = 1
    case product = 2
    case serialNumber = 3
    case timeCreated = 4
    case number = 5
}

/// Known field numbers for device_info messages (global message 23).
public enum FITDeviceInfoField: UInt8 {
    case timestamp = 253
    case deviceIndex = 0
    case deviceType = 1
    case manufacturer = 2
    case serialNumber = 3
    case product = 4
    case softwareVersion = 5
    case hardwareVersion = 6
    case productName = 27
}

/// Known field numbers for activity messages (global message 34).
public enum FITActivityField: UInt8 {
    case timestamp = 253
    case totalTimerTime = 0
    case localTimestamp = 1
    case numSessions = 2
    case type = 3
    case event = 4
    case eventType = 5
    case eventGroup = 6
}

// MARK: - FIT Sport Values

/// FIT sport enum values from the profile.
public enum FITSport: UInt8, Sendable {
    case generic = 0
    case running = 1
    case cycling = 2
    case transition = 3
    case fitnessEquipment = 4
    case swimming = 5
    case basketball = 6
    case soccer = 7
    case tennis = 8
    case americanFootball = 9
    case training = 10
    case walking = 11
    case crossCountrySkiing = 12
    case alpineSkiing = 13
    case snowboarding = 14
    case rowing = 15
    case mountaineering = 16
    case hiking = 17
    case multisport = 18
    case paddling = 19
    case flying = 20
    case eBiking = 21
    case motorcycling = 22
    case boating = 23
    case driving = 24
    case golf = 25
    case hangGliding = 26
    case horsebackRiding = 27
    case hunting = 28
    case fishing = 29
    case inlineSkating = 30
    case rockClimbing = 31
    case sailing = 32
    case iceSkating = 33
    case skyDiving = 34
    case snowshoeing = 35
    case snowmobiling = 36
    case standUpPaddleboarding = 37
    case surfing = 38
    case wakeboarding = 39
    case waterSkiing = 40
    case kayaking = 41
    case rafting = 42
    case windsurfing = 43
    case kitesurfing = 44
    case tactical = 45
    case jumpmaster = 46
    case boxing = 47
    case floorClimbing = 48
    case baseball = 49
    case diving = 53
    case hiit = 62
    case racket = 64
    case waterTubing = 76
    case wakesurfing = 77
    case all = 254

    /// Whether this sport represents a running activity.
    public var isRunning: Bool {
        self == .running
    }
}
