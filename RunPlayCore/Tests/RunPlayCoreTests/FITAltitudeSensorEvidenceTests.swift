import Foundation
import XCTest
@testable import RunPlayCore

/// A FIT file's recorded altitude counts as barometric only when a
/// `device_info` message declares a local (5) barometer (4). The FIT profile
/// citations live on `FITAltitudeSensorEvidence`.
final class FITAltitudeSensorEvidenceTests: XCTestCase {
    private typealias DeviceInfoSpec = FITMultiSessionFixtureBuilder.DeviceInfoSpec

    func testLocalBarometerIsBarometricEvidence() {
        let messages = [
            deviceInfo(index: 0, type: nil, source: 5),
            deviceInfo(index: 1, type: 4, source: 5),
            deviceInfo(index: 2, type: 0, source: 5),
        ]
        XCTAssertEqual(FITAltitudeSensorEvidence.recordedAltitudeSensor(in: messages), .barometric)
    }

    func testDeviceTypeFourIsNotEvidenceWithoutALocalSource() {
        // Without a local source, device type 4 reads through another table
        // or none: Bluetooth LE (3) bike speed, an undefined ANT+ (1) value, a
        // bare ANT (0) number, or no subfield for Bluetooth (2), Wi-Fi (4) or
        // an absent source. None of them is the onboard barometer.
        for source in [UInt8?.none, 0, 1, 2, 3, 4] {
            let messages = [deviceInfo(index: 1, type: 4, source: source)]
            XCTAssertEqual(
                FITAltitudeSensorEvidence.recordedAltitudeSensor(in: messages),
                .unknown,
                "source type \(source.map(String.init) ?? "absent")"
            )
        }
    }

    func testFilesWithoutABarometerRecordAreUnknown() {
        XCTAssertEqual(FITAltitudeSensorEvidence.recordedAltitudeSensor(in: []), .unknown)
        let gpsAndHeartRate = [
            deviceInfo(index: 2, type: 0, source: 5),
            deviceInfo(index: 4, type: 10, source: 5),
        ]
        XCTAssertEqual(FITAltitudeSensorEvidence.recordedAltitudeSensor(in: gpsAndHeartRate), .unknown)
    }

    func testImportedWorkoutCarriesTheEvidence() throws {
        let barometric = try importFixture(deviceInfos: [
            DeviceInfoSpec(deviceIndex: 0, deviceType: nil, sourceType: 5),
            DeviceInfoSpec(deviceIndex: 1, deviceType: 4, sourceType: 5),
        ])
        XCTAssertEqual(barometric.recordedAltitudeSensor, .barometric)

        let gpsOnly = try importFixture(deviceInfos: [
            DeviceInfoSpec(deviceIndex: 2, deviceType: 0, sourceType: 5),
        ])
        XCTAssertEqual(gpsOnly.recordedAltitudeSensor, .unknown)

        let noDeviceInfo = try importFixture(deviceInfos: [])
        XCTAssertEqual(noDeviceInfo.recordedAltitudeSensor, .unknown)
    }

    // MARK: - Helpers

    private func deviceInfo(index: UInt8, type: UInt8?, source: UInt8?) -> FITDeviceInfoMessage {
        var message = FITDeviceInfoMessage()
        message.deviceIndex = index
        message.deviceType = type
        message.sourceType = source
        return message
    }

    private func importFixture(deviceInfos: [DeviceInfoSpec]) throws -> RunWorkout {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<4).map { step in
                FITMultiSessionFixtureBuilder.RecordSpec(
                    offsetSeconds: UInt32(step * 10),
                    coordinateStep: Int32(step * 2_000)
                )
            },
            sessions: [FITMultiSessionFixtureBuilder.SessionSpec(startOffsetSeconds: 0, endOffsetSeconds: 30)],
            deviceInfos: deviceInfos
        )
        return try FITImporter().importWorkout(data: data, suggestedName: "Evidence")
    }
}
