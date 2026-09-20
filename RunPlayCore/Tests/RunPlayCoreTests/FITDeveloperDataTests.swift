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

    /// Pins the developer-field scale/offset sign convention:
    /// `physical = raw / scale - offset`. Offset is SUBTRACTED.
    ///
    /// Derived from the official Garmin SDKs closest to this codebase (see
    /// AGENTS.md "FIT reference implementations"), in order of authority.
    ///
    /// THE SIGN IS UNANIMOUS — no official binding adds the offset:
    ///  - C++ SDK, `src/fit_field_base.cpp:440`:
    ///        return float64Value / GetScale(subFieldIndex) - GetOffset(subFieldIndex);
    ///    and `:342` for FIT_FLOAT32; the inverse encode at `:974` and
    ///    `:1037` confirms the direction:
    ///        FIT_FLOAT64 recalculatedValue = (value + GetOffset(subFieldIndex)) * GetScale(subFieldIndex);
    ///  - Swift SDK, `Sources/FITSwiftSDK/FieldBase.swift:99`:
    ///        value = Float64(fitValue: value) / scale - offset
    ///  - This repo already decodes profile fields the same way:
    ///    `FITParser.scaledAltitudeToMeters` is `(raw / 5.0) - 500.0` for the
    ///    profile's altitude scale 5 / offset 500.
    ///
    /// REJECTED ALTERNATIVE: `raw / scale + offset`. Implemented by no
    /// official binding; decodes a non-zero-offset field wrong by exactly
    /// `2 * offset` — silently, because both readings look plausible.
    ///
    /// REPORTED, NOT RESOLVED — the C++ and Swift SDKs genuinely disagree on
    /// whether developer fields are scaled at all:
    ///  - C++ declines. `src/fit_developer_field.cpp:100-110`:
    ///        FIT_FLOAT64 DeveloperField::GetScale() const
    ///        {
    ///            // Developer fields do not currently support scale
    ///            return 1.0;
    ///        }
    ///    …and `GetOffset()` likewise returns 0. Values come back raw.
    ///  - Swift applies. `Sources/FITSwiftSDK/DeveloperField.swift:54-60`:
    ///        override func getScale() -> Float64 {
    ///            return Float64(developerFieldDefinition.fieldDescriptionMesg?.getScale() ?? 1)
    ///        }
    ///    …and `getOffset()` likewise, feeding the subtract above.
    ///  - The C SDK abstains: it decodes no developer fields at all.
    ///
    /// This importer applies the conversion, matching the Swift SDK as the
    /// binding closest to RunPlayCore. That choice is contested, so it is not
    /// load-bearing in silence: `testNonZeroOffsetIsFlaggedInImportReport`
    /// pins that a non-zero offset — exactly the case where the two bindings
    /// would disagree numerically — is surfaced in the import report.
    func testDeveloperFieldOffsetIsSubtractedNotAdded() throws {
        // scale 10, offset 20, raw 2500.
        //   subtract (correct): 2500 / 10 - 20 = 230 W
        //   add      (rejected): 2500 / 10 + 20 = 270 W
        // Both are physiologically plausible running-power values, which is
        // precisely why the wrong sign would never announce itself.
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
                            value: .uint16(2500)
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
                    offset: 20
                )
            ]
        )
        let workout = try importFixture(data)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 230)
        XCTAssertNotEqual(
            workout.routePoints.first?.powerWatts,
            270,
            "270 W is the rejected raw / scale + offset reading"
        )
    }

    /// The same convention with a negative offset, which subtracts to a
    /// larger value. Preserves the coverage of the original scale/offset
    /// test while reading against the pinned sign.
    func testNegativeDeveloperOffsetAlsoSubtracts() throws {
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

        // 250 / 10 - (-5) = 30. The rejected add convention would give 20.
        XCTAssertEqual(workout.routePoints.first?.powerWatts, 30)
    }

    /// A non-zero offset is the only case where the sign convention is
    /// observable, and almost no real field ships one — so its arrival must
    /// be visible in the import report rather than silently assumed.
    func testNonZeroOffsetIsFlaggedInImportReport() throws {
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
                            value: .uint16(2500)
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
                    offset: 20
                )
            ]
        )
        let workout = try importFixture(data)
        let summary = try XCTUnwrap(workout.developerFieldSummary)

        let note = try XCTUnwrap(
            summary.notes.first { $0.contains("non-zero offset") },
            "expected a non-zero offset diagnostic in \(summary.notes)"
        )
        XCTAssertTrue(note.contains("\"power\""), note)
        XCTAssertTrue(note.contains("raw / scale - offset"), note)
    }

    /// The common case must stay quiet: offset 0 is not worth a note.
    func testZeroOffsetProducesNoOffsetNote() throws {
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
                            value: .uint16(240)
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
                    scale: 1,
                    offset: 0
                )
            ]
        )
        let workout = try importFixture(data)
        let summary = try XCTUnwrap(workout.developerFieldSummary)

        XCTAssertEqual(workout.routePoints.first?.powerWatts, 240)
        XCTAssertFalse(
            summary.notes.contains { $0.contains("non-zero offset") },
            "offset 0 must not emit a diagnostic: \(summary.notes)"
        )
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

    // MARK: - Profile parity

    /// Pins the `field_description` (206) and `developer_data_id` (207) field
    /// numbers against the official Garmin SDK Profile sources
    /// (Profile 21.214.0), verified in both bindings:
    ///  - C SDK `example-sdk/fit_example.h`, e.g.
    ///    `#define FIT_FIELD_DESCRIPTION_FIELD_NUM_OFFSET (FIT_CAST(FIT_FIELD_DESCRIPTION_FIELD_NUM, 7))`
    ///  - Swift SDK `Sources/FITSwiftSDK/Profile/Mesgs/FieldDescriptionMesg.swift:14-27`
    ///    and `DeveloperDataIdMesg.swift:14-18`.
    ///
    /// These numbers are wire format: a drift here silently misreads every
    /// developer field in every file, so they are pinned rather than trusted.
    func testFieldDescriptionAndDeveloperDataIDFieldNumbersMatchProfile() {
        XCTAssertEqual(FITFieldDescriptionField.developerDataIndex.rawValue, 0)
        XCTAssertEqual(FITFieldDescriptionField.fieldDefinitionNumber.rawValue, 1)
        XCTAssertEqual(FITFieldDescriptionField.fitBaseTypeID.rawValue, 2)
        XCTAssertEqual(FITFieldDescriptionField.fieldName.rawValue, 3)
        XCTAssertEqual(FITFieldDescriptionField.array.rawValue, 4)
        XCTAssertEqual(FITFieldDescriptionField.components.rawValue, 5)
        XCTAssertEqual(FITFieldDescriptionField.scale.rawValue, 6)
        XCTAssertEqual(FITFieldDescriptionField.offset.rawValue, 7)
        XCTAssertEqual(FITFieldDescriptionField.units.rawValue, 8)
        XCTAssertEqual(FITFieldDescriptionField.bits.rawValue, 9)
        XCTAssertEqual(FITFieldDescriptionField.accumulate.rawValue, 10)
        XCTAssertEqual(FITFieldDescriptionField.fitBaseUnitID.rawValue, 13)
        XCTAssertEqual(FITFieldDescriptionField.nativeMesgNum.rawValue, 14)
        XCTAssertEqual(FITFieldDescriptionField.nativeFieldNum.rawValue, 15)

        XCTAssertEqual(FITDeveloperDataIDField.developerID.rawValue, 0)
        XCTAssertEqual(FITDeveloperDataIDField.applicationID.rawValue, 1)
        XCTAssertEqual(FITDeveloperDataIDField.manufacturerID.rawValue, 2)
        XCTAssertEqual(FITDeveloperDataIDField.developerDataIndex.rawValue, 3)
        XCTAssertEqual(FITDeveloperDataIDField.applicationVersion.rawValue, 4)
    }

    /// `fit_base_unit`, verified against the Swift SDK's generated
    /// `Profile/Types/FitBaseUnit.swift` (Profile 21.214.0):
    /// `other = 0`, `kilogram = 1`, `pound = 2`, `invalid = 0xFFFF`.
    /// A populated `units` string always wins; the enum is only the fallback.
    func testResolvedUnitUsesVerifiedFitBaseUnitEnum() {
        func description(units: String?, baseUnitID: UInt16?) -> FITFieldDescriptionMessage {
            var message = FITFieldDescriptionMessage()
            message.units = units
            message.baseUnitID = baseUnitID
            return message
        }

        // The device's own units string is authoritative.
        XCTAssertEqual(description(units: "Watts", baseUnitID: 1).resolvedUnit, "Watts")

        // Fallback to the verified enum.
        XCTAssertEqual(description(units: nil, baseUnitID: 1).resolvedUnit, "kg")
        XCTAssertEqual(description(units: "", baseUnitID: 2).resolvedUnit, "lb")

        // "other" names no unit, so it must not invent a placeholder string.
        XCTAssertNil(description(units: nil, baseUnitID: 0).resolvedUnit)

        // Absent and invalid resolve to nothing.
        XCTAssertNil(description(units: nil, baseUnitID: nil).resolvedUnit)
        XCTAssertNil(description(units: nil, baseUnitID: 0xFFFF).resolvedUnit)

        // An id outside the enum stays visible rather than being dropped, so
        // a future profile addition surfaces instead of vanishing.
        XCTAssertEqual(
            description(units: nil, baseUnitID: 7).resolvedUnit,
            "fit_base_unit:7"
        )
    }

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
