import Foundation
import XCTest
@testable import RunPlayCore

/// Developer-data decoding: field_description (206), developer_data_id
/// (207), record developer fields, recognition, and the persisted summary.
final class FITDeveloperDataTests: XCTestCase {

    private typealias RecordSpec = FITMultiSessionFixtureBuilder.RecordSpec
    private typealias SessionSpec = FITMultiSessionFixtureBuilder.SessionSpec
    private typealias DeveloperValueSpec = FITMultiSessionFixtureBuilder.DeveloperValueSpec
    private typealias FieldDescriptionSpec = FITMultiSessionFixtureBuilder.FieldDescriptionSpec
    private typealias DeveloperDataIDSpec = FITMultiSessionFixtureBuilder.DeveloperDataIDSpec

    // MARK: - Parser

    func testFieldDescriptionAndDeveloperDataIDMessagesDecode() throws {
        let data = FITMultiSessionFixtureBuilder.singleRunningSessionWithDeveloperFields()
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.developerDataIDs.count, 1)
        let identity = try XCTUnwrap(decoded.developerDataIDs.first)
        XCTAssertEqual(identity.developerDataIndex, 0)
        XCTAssertEqual(
            identity.applicationID,
            Data([
                0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0x02
            ])
        )
        XCTAssertEqual(identity.manufacturerID, 255)
        XCTAssertEqual(identity.applicationVersion, 0x0102_0304)

        XCTAssertEqual(decoded.fieldDescriptions.count, 4)
        let power = try XCTUnwrap(
            decoded.fieldDescriptions.first { $0.fieldName == "power" }
        )
        XCTAssertEqual(power.developerDataIndex, 0)
        XCTAssertEqual(power.fieldDefinitionNumber, 0)
        XCTAssertEqual(power.baseType, .uint16)
        XCTAssertEqual(power.units, "watts")
        XCTAssertEqual(power.effectiveScale, 1)
        XCTAssertEqual(power.effectiveOffset, 0)

        // Every record captured its developer payloads.
        XCTAssertGreaterThan(decoded.records.count, 0)
        XCTAssertTrue(decoded.records.allSatisfy { $0.developerFields.count == 4 })
    }

    func testOutOfOrderDescriptionsStillResolve() throws {
        // Descriptions trail the records that reference them; resolution
        // happens after the whole file is parsed.
        let data = FITMultiSessionFixtureBuilder
            .singleRunningSessionWithDeveloperFields(descriptionsFollowRecords: true)
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 200)
        XCTAssertEqual(workout.routePoints.last?.powerWatts, 200 + Double(workout.routePoints.count - 1) * 5)
    }

    func testMissingFieldDescriptionCountsSkippedValues() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 9,
                            baseType: .uint16,
                            value: .uint16(123)
                        )
                    ]
                ),
                RecordSpec(offsetSeconds: 10, coordinateStep: 2_000)
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 10)]
        )
        let workout = try importFixture(data)

        // The route remains valid; the undescribed value is counted, not guessed.
        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertNil(workout.routePoints.first?.powerWatts)
        let summary = try XCTUnwrap(workout.developerFieldSummary)
        XCTAssertTrue(summary.notes.contains { $0.contains("no field_description") })
    }

    // MARK: - Value conversion

    func testScaleAndOffsetConvertRawValues() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .uint16,
                            value: .uint16(250)
                        )
                    ]
                )
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 0)],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power",
                    units: "watts",
                    scale: 10,
                    offset: -5
                )
            ]
        )
        let workout = try importFixture(data)

        // FIT protocol: physical = raw / scale + offset → 250 / 10 − 5 = 20.
        XCTAssertEqual(workout.routePoints.first?.powerWatts, 20)
    }

    func testSignedAndFloatBaseTypesDecode() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .sint16,
                            value: .sint16(-42)
                        ),
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 1,
                            baseType: .float32,
                            value: .float32(12.5)
                        )
                    ]
                )
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 0)],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .sint16,
                    fieldName: "power"
                ),
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 1,
                    baseType: .float32,
                    fieldName: "vertical oscillation"
                )
            ]
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, -42)
        XCTAssertEqual(workout.routePoints.first?.verticalOscillationMillimeters ?? 0, 12.5, accuracy: 0.0001)
    }

    func testInvalidSentinelsAreTreatedAsMissing() throws {
        // One record carries real values, the next omits them (sentinels).
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .uint16,
                            value: .uint16(220)
                        )
                    ]
                ),
                RecordSpec(offsetSeconds: 10, coordinateStep: 2_000)
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 10)],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power"
                )
            ]
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 220)
        XCTAssertNil(workout.routePoints.last?.powerWatts)
        let field = try XCTUnwrap(
            workout.developerFieldSummary?.fields.first { $0.mappedMetric == "powerWatts" }
        )
        XCTAssertEqual(field.sampleCount, 1)
    }

    // MARK: - Recognition and provenance

    func testMultipleDeveloperApplicationsResolveIndependently() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .uint16,
                            value: .uint16(210)
                        ),
                        DeveloperValueSpec(
                            developerDataIndex: 1,
                            fieldNumber: 2,
                            baseType: .uint16,
                            value: .uint16(250)
                        )
                    ]
                )
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 0)],
            developerDataIDs: [
                DeveloperDataIDSpec(
                    developerDataIndex: 0,
                    applicationID: Data(repeating: 0x0A, count: 16),
                    manufacturerID: 1
                ),
                DeveloperDataIDSpec(
                    developerDataIndex: 1,
                    applicationID: Data(repeating: 0x0B, count: 16),
                    manufacturerID: 2
                )
            ],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power"
                ),
                FieldDescriptionSpec(
                    developerDataIndex: 1,
                    fieldDefinitionNumber: 2,
                    baseType: .uint16,
                    fieldName: "power"
                )
            ]
        )
        let workout = try importFixture(data)

        // First developer source wins; the conflict is reported, not guessed.
        XCTAssertEqual(workout.routePoints.first?.powerWatts, 210)
        let summary = try XCTUnwrap(workout.developerFieldSummary)
        XCTAssertEqual(summary.sources.count, 2)
        XCTAssertEqual(summary.powerSourceDeveloperDataIndex, 0)
        XCTAssertTrue(summary.notes.contains { $0.contains("more than one developer source") })

        // Both fields appear in the statistics with their own provenance.
        let powerFields = summary.fields.filter { $0.mappedMetric == "powerWatts" }
        XCTAssertEqual(powerFields.count, 2)
        XCTAssertEqual(Set(powerFields.map(\.developerDataIndex)), [0, 1])
    }

    func testNameMatchingRecognizesCommonVendorSpellings() {
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Power"), .power)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "  ground   TIME "), .groundContactTime)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Ground Contact Time"), .groundContactTime)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Vertical Oscillation"), .verticalOscillation)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "vertical ratio"), .verticalRatio)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Stance Time Balance"), .stanceTimeBalance)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Step Length"), .stepLength)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Form Power"), .formPower)
        XCTAssertEqual(FITDeveloperMetric.match(fieldName: "Leg Spring Stiffness"), .legSpringStiffness)
        XCTAssertNil(FITDeveloperMetric.match(fieldName: "Air Power"))
        XCTAssertNil(FITDeveloperMetric.match(fieldName: ""))
    }

    // MARK: - Native record power

    func testNativeRecordPowerMapsToPowerWatts() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(offsetSeconds: 0, coordinateStep: 0, nativePowerWatts: 232),
                RecordSpec(offsetSeconds: 10, coordinateStep: 2_000)
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 10)],
            includeNativePowerField: true
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 232)
        XCTAssertNil(workout.routePoints.last?.powerWatts)
        let summary = try XCTUnwrap(workout.developerFieldSummary)
        XCTAssertTrue(summary.powerSourceIsNativeRecordField)
        XCTAssertNil(summary.powerSourceDeveloperDataIndex)
    }

    func testDeveloperPowerWinsOverNativePower() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .uint16,
                            value: .uint16(205)
                        )
                    ],
                    nativePowerWatts: 232
                )
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 0)],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power"
                )
            ],
            includeNativePowerField: true
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 205)
    }

    // MARK: - Persisted summary

    func testEndToEndSummaryPersistsFieldsProvenanceAndNotes() throws {
        let data = FITMultiSessionFixtureBuilder
            .singleRunningSessionWithDeveloperFields()
        let workout = try importFixture(data)

        // Dynamics landed on the points.
        XCTAssertEqual(workout.routePoints.first?.groundContactTimeMilliseconds, 240)
        XCTAssertEqual(workout.routePoints.first?.verticalOscillationMillimeters, 8)
        XCTAssertNil(workout.routePoints.first?.stepLengthMeters)

        let summary = try XCTUnwrap(workout.developerFieldSummary)
        XCTAssertEqual(summary.sources.count, 1)
        XCTAssertEqual(summary.sources.first?.applicationIDHex, "112233445566778899aabbccddee0102")
        XCTAssertEqual(summary.powerSourceDeveloperDataIndex, 0)
        XCTAssertFalse(summary.powerSourceIsNativeRecordField)

        // Three mapped fields plus one retained unknown field.
        let mapped = summary.fields.filter { $0.status == .mapped }
        XCTAssertEqual(
            Set(mapped.map(\.mappedMetric)),
            ["powerWatts", "groundContactTimeMilliseconds", "verticalOscillationMillimeters"]
        )
        let airPower = try XCTUnwrap(summary.fields.first { $0.fieldName == "Air Power" })
        XCTAssertEqual(airPower.status, .retained)
        XCTAssertEqual(airPower.unit, "watts")
        XCTAssertEqual(airPower.sampleCount, workout.routePoints.count)
        XCTAssertEqual(airPower.coverage, 1.0, accuracy: 0.0001)
        let mean = try XCTUnwrap(airPower.mean)
        XCTAssertEqual(mean, (50 + Double(50 + workout.routePoints.count - 1)) / 2, accuracy: 0.001)

        // Round-trip through the snapshot keeps the summary.
        let encoded = try JSONEncoder().encode(workout)
        let decoded = try JSONDecoder().decode(RunWorkout.self, from: encoded)
        XCTAssertEqual(decoded.developerFieldSummary, summary)
    }

    func testRetainedFieldCapTruncatesWithNote() throws {
        var descriptions: [FieldDescriptionSpec] = []
        for fieldNumber in 0..<(WorkoutDeveloperFieldSummary.maximumRetainedFieldCount + 3) {
            descriptions.append(FieldDescriptionSpec(
                developerDataIndex: 0,
                fieldDefinitionNumber: UInt8(fieldNumber),
                baseType: .uint16,
                fieldName: "mystery\(fieldNumber)"
            ))
        }
        let valueCount = descriptions.count
        var records: [RecordSpec] = []
        for index in 0..<4 {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                developerFields: descriptions.map { description in
                    DeveloperValueSpec(
                        developerDataIndex: 0,
                        fieldNumber: description.fieldDefinitionNumber,
                        baseType: .uint16,
                        value: .uint16(UInt16(10 + index))
                    )
                }
            ))
        }
        // Keep every declared field present on the shared record definition.
        let data = FITMultiSessionFixtureBuilder.build(
            records: records,
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 30)],
            fieldDescriptions: descriptions
        )
        let workout = try importFixture(data)

        let summary = try XCTUnwrap(workout.developerFieldSummary)
        XCTAssertEqual(summary.fields.count, WorkoutDeveloperFieldSummary.maximumRetainedFieldCount)
        XCTAssertTrue(summary.notes.contains { $0.contains("not retained") })
        // All captured values still parsed; only persistence is capped.
        XCTAssertEqual(valueCount, descriptions.count)
    }

    func testWorkoutWithoutDeveloperDataHasNoSummary() throws {
        let data = FITMultiSessionFixtureBuilder.singleRunningSession()
        let workout = try importFixture(data)

        XCTAssertNil(workout.developerFieldSummary)
    }

    func testLegacySnapshotJSONDecodesWithoutDeveloperSummary() throws {
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Legacy"),
            source: .fit,
            routePoints: [
                RoutePoint(timestamp: Date(timeIntervalSince1970: 0), latitude: 1, longitude: 1)
            ]
        )
        let encoded = try JSONEncoder().encode(workout)
        let container = try JSONDecoder().decode(
            [String: Value].self,
            from: encoded
        )
        // The key is only written when a summary exists.
        XCTAssertNil(container["developerFieldSummary"])
    }

    func testAccumulatingFieldDecodesInstantaneouslyWithNote() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: [
                RecordSpec(
                    offsetSeconds: 0,
                    coordinateStep: 0,
                    developerFields: [
                        DeveloperValueSpec(
                            developerDataIndex: 0,
                            fieldNumber: 0,
                            baseType: .uint16,
                            value: .uint16(250)
                        )
                    ]
                )
            ],
            sessions: [SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 0)],
            fieldDescriptions: [
                FieldDescriptionSpec(
                    developerDataIndex: 0,
                    fieldDefinitionNumber: 0,
                    baseType: .uint16,
                    fieldName: "power",
                    accumulate: "accumulate"
                )
            ]
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 250)
        XCTAssertTrue(
            workout.developerFieldSummary?.notes.contains {
                $0.contains("accumulation")
            } ?? false
        )
    }

    // MARK: - Helpers

    private func importFixture(_ data: Data) throws -> RunWorkout {
        try FITImporter().importWorkout(data: data, suggestedName: "Developer Fields Fixture")
    }
}

/// Minimal JSON value container for key-presence assertions.
private enum Value: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([Value])
    case object([String: Value])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: Value].self) {
            self = .object(object)
        } else if let array = try? container.decode([Value].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}
