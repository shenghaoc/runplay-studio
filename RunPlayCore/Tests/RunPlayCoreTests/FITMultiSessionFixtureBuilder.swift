import Foundation
@testable import RunPlayCore

/// Builds synthetic multi-session FIT binaries for tests.
///
/// Entirely synthetic: no real workout data, coordinates, or device identifiers
/// are committed to the repository.
enum FITMultiSessionFixtureBuilder {

    static let baseTimestamp: UInt32 = 1_000_000_000

    /// Raw payload for one record developer field.
    enum DeveloperRawValue {
        case uint8(UInt8)
        case uint16(UInt16)
        case sint16(Int16)
        case uint32(UInt32)
        case float32(Float32)
    }

    /// One developer field value written into a record message.
    struct DeveloperValueSpec {
        var developerDataIndex: UInt8
        var fieldNumber: UInt8
        var baseType: FITBaseType
        var value: DeveloperRawValue
    }

    /// One `field_description` message (global 206).
    struct FieldDescriptionSpec {
        var developerDataIndex: UInt8
        var fieldDefinitionNumber: UInt8
        var baseType: FITBaseType
        var fieldName: String
        var units: String? = nil
        var scale: UInt8? = nil
        var offset: Int8? = nil
        var accumulate: String? = nil
    }

    /// One `developer_data_id` message (global 207).
    struct DeveloperDataIDSpec {
        var developerDataIndex: UInt8
        var applicationID: Data? = nil
        var developerID: Data? = nil
        var manufacturerID: UInt16? = nil
        var applicationVersion: UInt32? = nil
    }

    struct RecordSpec {
        var offsetSeconds: UInt32
        var hasValidTimestamp: Bool = true
        var hasValidCoordinates: Bool = true
        /// Semicircle offset applied to the fixture's base coordinate.
        var coordinateStep: Int32 = 0
        var distanceMeters: Double = 0
        /// Developer field payloads; the definition is the union across specs.
        var developerFields: [DeveloperValueSpec] = []
        /// Native record power field 7 (watts). Only written when the build
        /// enables the native power field.
        var nativePowerWatts: UInt16? = nil
        /// Native running-dynamics record fields (raw uint16 values). Only
        /// written when the build enables the native dynamics fields;
        /// omitted fields encode the 0xFFFF invalid sentinel.
        var nativeDynamics: NativeDynamicsSpec? = nil
    }

    /// Raw native running-dynamics record values. Field numbers, scales,
    /// and units per the official Garmin FIT SDK Profile 21.214.0: 39
    /// vertical oscillation scale 10 mm, 40 stance time percent scale 100
    /// percent, 41 stance time scale 10 ms, 83 vertical ratio scale 100
    /// percent, 84 stance time balance scale 100 percent, 85 step length
    /// scale 10 mm.
    struct NativeDynamicsSpec {
        var verticalOscillation: UInt16? = nil
        var stanceTimePercent: UInt16? = nil
        var stanceTime: UInt16? = nil
        var verticalRatio: UInt16? = nil
        var stanceTimeBalance: UInt16? = nil
        var stepLength: UInt16? = nil
    }

    struct EventSpec {
        var offsetSeconds: UInt32
        var timerEventType: UInt8
        var hasValidTimestamp: Bool = true
    }

    struct LapSpec {
        var messageIndex: UInt16?
        var startOffsetSeconds: UInt32?
        var endOffsetSeconds: UInt32?
        var elapsedSeconds: UInt32 = 60
        var distanceMeters: UInt32 = 1_000
        var trigger: UInt8 = 0
    }

    struct SessionSpec {
        var startOffsetSeconds: UInt32?
        var endOffsetSeconds: UInt32?
        var sport: FITSport? = .running
        var subSport: UInt8 = 0
        var elapsedSeconds: UInt32 = 100
        /// Raw `total_elapsed_time` in milliseconds, bypassing `elapsedSeconds`.
        /// Use `0xFFFF_FFFF` to encode the FIT invalid-value sentinel.
        var elapsedMillisecondsOverride: UInt32?
        var timerSeconds: UInt32 = 100
        var distanceMeters: UInt32 = 1_000
        var firstLapIndex: UInt16 = 0xFFFF
        var numberOfLaps: UInt16 = 0xFFFF
    }

    /// One `device_info` message. `deviceType` means `local_device_type` only
    /// when `sourceType` is local (5); nil writes the FIT invalid value.
    struct DeviceInfoSpec {
        var deviceIndex: UInt8 = 0
        var deviceType: UInt8?
        var sourceType: UInt8?
    }

    /// One developer field declared on the shared record definition.
    struct RecordDeveloperDefinition {
        let developerDataIndex: UInt8
        let fieldNumber: UInt8
        let size: UInt8
        let baseType: UInt8
    }

    /// Assemble a FIT container from explicit message specifications.
    ///
    /// Messages are written developer ids → field descriptions → records →
    /// events → laps → sessions, which is the usual device layout (summary
    /// messages trail their samples). Set `descriptionsFollowRecords` to
    /// build the out-of-order case where descriptions trail their users.
    static func build(
        records: [RecordSpec],
        events: [EventSpec] = [],
        laps: [LapSpec] = [],
        sessions: [SessionSpec],
        developerDataIDs: [DeveloperDataIDSpec] = [],
        fieldDescriptions: [FieldDescriptionSpec] = [],
        descriptionsFollowRecords: Bool = false,
        includeNativePowerField: Bool = false,
        includeNativeDynamicsFields: Bool = false,
        deviceInfos: [DeviceInfoSpec] = []
    ) -> Data {
        var content = Data()

        if !deviceInfos.isEmpty {
            writeDeviceInfoDefinition(to: &content)
            for deviceInfo in deviceInfos {
                writeDeviceInfo(deviceInfo, to: &content)
            }
        }

        let developerDefinitions = recordDeveloperDefinitions(from: records)

        if !developerDataIDs.isEmpty {
            writeDeveloperDataIDDefinition(to: &content)
            for identity in developerDataIDs {
                writeDeveloperDataID(identity, to: &content)
            }
        }
        if !fieldDescriptions.isEmpty && !descriptionsFollowRecords {
            writeFieldDescriptionDefinition(to: &content)
            for description in fieldDescriptions {
                writeFieldDescription(description, to: &content)
            }
        }

        if !records.isEmpty {
            writeRecordDefinition(
                to: &content,
                developerFields: developerDefinitions,
                includePower: includeNativePowerField,
                includeDynamics: includeNativeDynamicsFields
            )
            for record in records {
                writeRecord(
                    record,
                    developerDefinitions: developerDefinitions,
                    includePower: includeNativePowerField,
                    includeDynamics: includeNativeDynamicsFields,
                    to: &content
                )
            }
        }

        if !fieldDescriptions.isEmpty && descriptionsFollowRecords {
            writeFieldDescriptionDefinition(to: &content)
            for description in fieldDescriptions {
                writeFieldDescription(description, to: &content)
            }
        }
        if !events.isEmpty {
            writeEventDefinition(to: &content)
            for event in events {
                writeEvent(event, to: &content)
            }
        }
        if !laps.isEmpty {
            writeLapDefinition(to: &content)
            for lap in laps {
                writeLap(lap, to: &content)
            }
        }
        if !sessions.isEmpty {
            writeSessionDefinition(to: &content)
            for session in sessions {
                writeSession(session, to: &content)
            }
        }

        return wrap(content: content)
    }

    /// Union of developer fields across record specs, in first-seen order.
    private static func recordDeveloperDefinitions(
        from records: [RecordSpec]
    ) -> [RecordDeveloperDefinition] {
        var definitions: [RecordDeveloperDefinition] = []
        var seen = Set<String>()
        for record in records {
            for value in record.developerFields {
                let key = "\(value.developerDataIndex)-\(value.fieldNumber)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                definitions.append(RecordDeveloperDefinition(
                    developerDataIndex: value.developerDataIndex,
                    fieldNumber: value.fieldNumber,
                    size: UInt8(value.baseType.byteSize),
                    baseType: value.baseType.rawValue
                ))
            }
        }
        return definitions
    }

    // MARK: - Convenience fixtures

    /// Two sequential, non-overlapping running sessions with distinct routes.
    static func twoSequentialRuns(
        firstRecordCount: Int = 10,
        secondRecordCount: Int = 10,
        gapSeconds: UInt32 = 600
    ) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<firstRecordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        let secondStart = UInt32(max(0, firstRecordCount - 1) * 10) + gapSeconds
        for index in 0..<secondRecordCount {
            records.append(RecordSpec(
                offsetSeconds: secondStart + UInt32(index * 10),
                coordinateStep: 500_000 + Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }

        let firstEnd = UInt32(max(0, firstRecordCount - 1) * 10)
        let secondEnd = secondStart + UInt32(max(0, secondRecordCount - 1) * 10)
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: firstEnd,
                    elapsedSeconds: firstEnd,
                    timerSeconds: firstEnd
                ),
                SessionSpec(
                    startOffsetSeconds: secondStart,
                    endOffsetSeconds: secondEnd,
                    elapsedSeconds: secondEnd - secondStart,
                    timerSeconds: secondEnd - secondStart
                )
            ]
        )
    }

    /// One running session followed by a session of another sport.
    static func runningPlus(sport: FITSport) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<10 {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        for index in 0..<10 {
            records.append(RecordSpec(
                offsetSeconds: 1_000 + UInt32(index * 10),
                coordinateStep: 500_000 + Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 90,
                    elapsedSeconds: 90,
                    timerSeconds: 90
                ),
                SessionSpec(
                    startOffsetSeconds: 1_000,
                    endOffsetSeconds: 1_090,
                    sport: sport,
                    elapsedSeconds: 90,
                    timerSeconds: 90
                )
            ]
        )
    }

    /// One ordinary single-session running file.
    static func singleRunningSession(recordCount: Int = 12) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<recordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        let end = UInt32(max(0, recordCount - 1) * 10)
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: end,
                    elapsedSeconds: end,
                    timerSeconds: end
                )
            ]
        )
    }

    /// A legacy container: GPS records but no session message at all.
    static func legacyNoSessions(recordCount: Int = 12) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<recordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        return build(records: records, sessions: [])
    }

    /// One single-session run whose records carry Stryd-style developer
    /// fields: power, ground time, vertical oscillation, plus one
    /// unrecognised "Air Power" field retained as metadata.
    static func singleRunningSessionWithDeveloperFields(
        recordCount: Int = 10,
        descriptionsFollowRecords: Bool = false
    ) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<recordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100,
                developerFields: [
                    DeveloperValueSpec(
                        developerDataIndex: 0,
                        fieldNumber: 0,
                        baseType: .uint16,
                        value: .uint16(UInt16(200 + index * 5))
                    ),
                    DeveloperValueSpec(
                        developerDataIndex: 0,
                        fieldNumber: 1,
                        baseType: .uint16,
                        value: .uint16(UInt16(240 + index))
                    ),
                    DeveloperValueSpec(
                        developerDataIndex: 0,
                        fieldNumber: 2,
                        baseType: .uint16,
                        value: .uint16(UInt16(8 + index % 3))
                    ),
                    DeveloperValueSpec(
                        developerDataIndex: 0,
                        fieldNumber: 3,
                        baseType: .uint16,
                        value: .uint16(UInt16(50 + index))
                    )
                ]
            ))
        }
        let end = UInt32(max(0, recordCount - 1) * 10)
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: end,
                    elapsedSeconds: end,
                    timerSeconds: end
                )
            ],
            developerDataIDs: [
                DeveloperDataIDSpec(
                    developerDataIndex: 0,
                    applicationID: Data([
                        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0x02
                    ]),
                    manufacturerID: 255,
                    applicationVersion: 0x0102_0304
                )
            ],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power",
                    units: "watts"
                ),
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 1,
                    baseType: .uint16,
                    fieldName: "Ground Time",
                    units: "ms"
                ),
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 2,
                    baseType: .uint16,
                    fieldName: "Vertical Oscillation",
                    units: "mm"
                ),
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 3,
                    baseType: .uint16,
                    fieldName: "Air Power",
                    units: "watts"
                )
            ],
            descriptionsFollowRecords: descriptionsFollowRecords
        )
    }

    // MARK: - Message writers

    private static func wrap(content: Data) -> Data {
        var data = Data()
        data.append(14)                                  // header length
        data.append(16)                                  // protocol version
        data.append(contentsOf: [0x40, 0x01])            // profile version
        data.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).littleEndian) { Array($0) })
        data.append(contentsOf: [0x2E, 0x46, 0x49, 0x54]) // ".FIT"
        data.append(contentsOf: [0x00, 0x00])            // header CRC placeholder

        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)

        data.append(content)
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
        return data
    }

    private static func field(_ number: UInt8, _ size: UInt8, _ type: UInt8, to data: inout Data) {
        data.append(number)
        data.append(size)
        data.append(type)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    // Records — local type 0
    private static func writeRecordDefinition(
        to data: inout Data,
        developerFields: [RecordDeveloperDefinition],
        includePower: Bool,
        includeDynamics: Bool
    ) {
        data.append(developerFields.isEmpty ? 0x40 : 0x60)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x14, 0x00]) // global 20
        data.append((includePower ? 7 : 6) + (includeDynamics ? 6 : 0))
        field(253, 4, 134, to: &data) // timestamp uint32
        field(0, 4, 133, to: &data)   // position_lat int32
        field(1, 4, 133, to: &data)   // position_long int32
        field(2, 2, 132, to: &data)   // altitude uint16
        field(5, 4, 134, to: &data)   // distance uint32
        field(6, 2, 132, to: &data)   // speed uint16
        if includePower {
            field(7, 2, 132, to: &data) // power uint16
        }
        if includeDynamics {
            field(39, 2, 132, to: &data) // vertical oscillation uint16
            field(40, 2, 132, to: &data) // stance time percent uint16
            field(41, 2, 132, to: &data) // stance time uint16
            field(83, 2, 132, to: &data) // vertical ratio uint16
            field(84, 2, 132, to: &data) // stance time balance uint16
            field(85, 2, 132, to: &data) // step length uint16
        }
        if !developerFields.isEmpty {
            data.append(UInt8(developerFields.count))
            for definition in developerFields {
                data.append(definition.fieldNumber)
                data.append(definition.size)
                data.append(definition.developerDataIndex)
            }
        }
    }

    private static let baseLatitude: Int32 = 12_780_237
    private static let baseLongitude: Int32 = 1_241_516_163

    private static func writeRecord(
        _ spec: RecordSpec,
        developerDefinitions: [RecordDeveloperDefinition],
        includePower: Bool,
        includeDynamics: Bool,
        to data: inout Data
    ) {
        data.append(0x00)
        appendUInt32(
            spec.hasValidTimestamp ? baseTimestamp + spec.offsetSeconds : UInt32.max,
            to: &data
        )
        if spec.hasValidCoordinates {
            appendInt32(baseLatitude + spec.coordinateStep, to: &data)
            appendInt32(baseLongitude + spec.coordinateStep, to: &data)
        } else {
            appendInt32(FITParser.invalidCoordinate, to: &data)
            appendInt32(FITParser.invalidCoordinate, to: &data)
        }
        appendUInt16(UInt16((20.0 + 500) * 5), to: &data)
        appendUInt32(UInt32(spec.distanceMeters * 100), to: &data)
        appendUInt16(3_000, to: &data)
        if includePower {
            appendUInt16(spec.nativePowerWatts ?? FITParser.invalidUint16, to: &data)
        }
        if includeDynamics {
            let dynamics = spec.nativeDynamics ?? NativeDynamicsSpec()
            appendUInt16(dynamics.verticalOscillation ?? FITParser.invalidUint16, to: &data)
            appendUInt16(dynamics.stanceTimePercent ?? FITParser.invalidUint16, to: &data)
            appendUInt16(dynamics.stanceTime ?? FITParser.invalidUint16, to: &data)
            appendUInt16(dynamics.verticalRatio ?? FITParser.invalidUint16, to: &data)
            appendUInt16(dynamics.stanceTimeBalance ?? FITParser.invalidUint16, to: &data)
            appendUInt16(dynamics.stepLength ?? FITParser.invalidUint16, to: &data)
        }
        for definition in developerDefinitions {
            if let value = spec.developerFields.first(where: {
                $0.developerDataIndex == definition.developerDataIndex
                    && $0.fieldNumber == definition.fieldNumber
            }) {
                data.append(contentsOf: developerValueBytes(value.value))
            } else {
                data.append(contentsOf: developerSentinelBytes(
                    for: definition.baseType,
                    size: Int(definition.size)
                ))
            }
        }
    }

    private static func developerValueBytes(_ value: DeveloperRawValue) -> [UInt8] {
        switch value {
        case .uint8(let raw):
            return [raw]
        case .uint16(let raw):
            return withUnsafeBytes(of: raw.littleEndian) { Array($0) }
        case .sint16(let raw):
            return withUnsafeBytes(
                of: UInt16(bitPattern: raw).littleEndian
            ) { Array($0) }
        case .uint32(let raw):
            return withUnsafeBytes(of: raw.littleEndian) { Array($0) }
        case .float32(let raw):
            return withUnsafeBytes(
                of: raw.bitPattern.littleEndian
            ) { Array($0) }
        }
    }

    /// Per-type invalid sentinels, so a spec can omit a developer value.
    private static func developerSentinelBytes(
        for baseType: UInt8,
        size: Int
    ) -> [UInt8] {
        switch baseType {
        case FITBaseType.uint16.rawValue:
            return [0xFF, 0xFF]
        case FITBaseType.uint32.rawValue:
            return [0xFF, 0xFF, 0xFF, 0xFF]
        case FITBaseType.sint16.rawValue:
            return [0xFF, 0x7F]
        case FITBaseType.float32.rawValue:
            return [0x00, 0x00, 0xC0, 0x7F] // NaN
        default:
            return Array(repeating: 0xFF, count: size)
        }
    }

    // Developer data IDs — local type 5
    private static func writeDeviceInfoDefinition(to data: inout Data) {
        data.append(0x46)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x17, 0x00]) // global 23
        data.append(3)
        field(0, 1, 2, to: &data)  // device_index uint8
        field(1, 1, 2, to: &data)  // device_type uint8
        field(25, 1, 0, to: &data) // source_type enum
    }

    private static func writeDeviceInfo(_ spec: DeviceInfoSpec, to data: inout Data) {
        data.append(0x06)
        data.append(spec.deviceIndex)
        data.append(spec.deviceType ?? 0xFF)
        data.append(spec.sourceType ?? 0xFF)
    }

    private static func writeDeveloperDataIDDefinition(to data: inout Data) {
        data.append(0x45)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0xCF, 0x00]) // global 207
        data.append(5)
        field(0, 16, 0x0D, to: &data) // developer_id byte[16]
        field(1, 16, 0x0D, to: &data) // application_id byte[16]
        field(2, 2, 132, to: &data)   // manufacturer_id uint16
        field(3, 1, 2, to: &data)     // developer_data_index uint8
        field(4, 4, 134, to: &data)   // application_version uint32
    }

    private static func writeDeveloperDataID(_ spec: DeveloperDataIDSpec, to data: inout Data) {
        data.append(0x05)
        data.append(contentsOf: spec.developerID ?? Data(repeating: 0xFF, count: 16))
        data.append(contentsOf: spec.applicationID ?? Data(repeating: 0xFF, count: 16))
        appendUInt16(spec.manufacturerID ?? FITParser.invalidUint16, to: &data)
        data.append(spec.developerDataIndex)
        appendUInt32(spec.applicationVersion ?? FITParser.invalidUint32, to: &data)
    }

    // Field descriptions — local type 4
    private static func writeFieldDescriptionDefinition(to data: inout Data) {
        data.append(0x44)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0xCE, 0x00]) // global 206
        data.append(8)
        field(0, 1, 2, to: &data)   // developer_data_index uint8
        field(1, 1, 2, to: &data)   // field_definition_number uint8
        field(2, 1, 0, to: &data)   // fit_base_type_id enum
        field(3, 24, 0x07, to: &data) // field_name string
        field(6, 1, 2, to: &data)   // scale uint8
        field(7, 1, 1, to: &data)   // offset sint8
        field(8, 12, 0x07, to: &data) // units string
        field(10, 12, 0x07, to: &data) // accumulate string
    }

    private static func writeFieldDescription(_ spec: FieldDescriptionSpec, to data: inout Data) {
        data.append(0x04)
        data.append(spec.developerDataIndex)
        data.append(spec.fieldDefinitionNumber)
        data.append(spec.baseType.rawValue)
        data.append(contentsOf: asciiBytes(spec.fieldName, capacity: 24))
        data.append(spec.scale ?? 1)
        data.append(UInt8(bitPattern: spec.offset ?? 0))
        data.append(contentsOf: asciiBytes(spec.units ?? "", capacity: 12))
        data.append(contentsOf: asciiBytes(spec.accumulate ?? "", capacity: 12))
    }

    /// Null-terminated ASCII payload padded to a fixed field size.
    private static func asciiBytes(_ text: String, capacity: Int) -> [UInt8] {
        var bytes = Array(text.utf8.prefix(capacity - 1))
        bytes.append(0)
        while bytes.count < capacity {
            bytes.append(0)
        }
        return bytes
    }

    // Events — local type 3
    private static func writeEventDefinition(to data: inout Data) {
        data.append(0x43)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x15, 0x00]) // global 21
        data.append(3)
        field(253, 4, 134, to: &data) // timestamp
        field(0, 1, 0, to: &data)     // event enum
        field(1, 1, 0, to: &data)     // event_type enum
    }

    private static func writeEvent(_ spec: EventSpec, to data: inout Data) {
        data.append(0x03)
        appendUInt32(
            spec.hasValidTimestamp ? baseTimestamp + spec.offsetSeconds : UInt32.max,
            to: &data
        )
        data.append(0) // event = timer
        data.append(spec.timerEventType)
    }

    // Laps — local type 2
    private static func writeLapDefinition(to data: inout Data) {
        data.append(0x42)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x13, 0x00]) // global 19
        data.append(7)
        field(254, 2, 132, to: &data) // message_index
        field(253, 4, 134, to: &data) // timestamp
        field(2, 4, 134, to: &data)   // start_time
        field(7, 4, 134, to: &data)   // total_elapsed_time
        field(8, 4, 134, to: &data)   // total_timer_time
        field(9, 4, 134, to: &data)   // total_distance
        field(24, 1, 0, to: &data)    // lap_trigger
    }

    private static func writeLap(_ spec: LapSpec, to data: inout Data) {
        data.append(0x02)
        appendUInt16(spec.messageIndex ?? UInt16.max, to: &data)
        appendUInt32(spec.endOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.startOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.distanceMeters * 100, to: &data)
        data.append(spec.trigger)
    }

    // Sessions — local type 1
    private static func writeSessionDefinition(to data: inout Data) {
        data.append(0x41)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x12, 0x00]) // global 18
        data.append(9)
        field(253, 4, 134, to: &data) // timestamp
        field(2, 4, 134, to: &data)   // start_time
        field(5, 1, 0, to: &data)     // sport
        field(6, 1, 0, to: &data)     // sub_sport
        field(7, 4, 134, to: &data)   // total_elapsed_time
        field(8, 4, 134, to: &data)   // total_timer_time
        field(9, 4, 134, to: &data)   // total_distance
        field(25, 2, 132, to: &data)  // first_lap_index
        field(26, 2, 132, to: &data)  // num_laps
    }

    private static func writeSession(_ spec: SessionSpec, to data: inout Data) {
        data.append(0x01)
        appendUInt32(spec.endOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.startOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        data.append(spec.sport?.rawValue ?? UInt8.max)
        data.append(spec.subSport)
        appendUInt32(spec.elapsedMillisecondsOverride ?? spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.timerSeconds * 1_000, to: &data)
        appendUInt32(spec.distanceMeters * 100, to: &data)
        appendUInt16(spec.firstLapIndex, to: &data)
        appendUInt16(spec.numberOfLaps, to: &data)
    }
}

/// Deterministic non-cryptographic digest for core tests.
///
/// Identity tests assert stability and distinctness, which this satisfies
/// without pulling CryptoKit into the Linux-clean core test target. The real
/// SHA-256 path is exercised by `CryptoKitContentDigest` in platform tests.
struct TestContentDigest: ContentDigesting {
    func sha256Hex(of data: Data) -> String {
        // Two independent FNV-1a lanes widened to a 64-hex-character string, so
        // the shape matches a real digest and short tuples stay distinct.
        var low: UInt64 = 0xcbf2_9ce4_8422_2325
        var high: UInt64 = 0x9e37_79b9_7f4a_7c15
        for byte in data {
            low = (low ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            high = (high &+ UInt64(byte) &+ 1) &* 0x0000_0100_0000_01B3
            high ^= high >> 29
        }
        let block = String(format: "%016lx%016lx", low, high)
        return block + block
    }
}
