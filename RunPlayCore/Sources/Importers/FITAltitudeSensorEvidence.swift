import Foundation

/// Reads, from a FIT file's `device_info` messages, whether its recorded
/// altitude comes from an onboard barometric altimeter.
///
/// `device_info.device_type` (field 1) is a dynamic field whose meaning depends
/// on `source_type` (field 25): only when the source is local (5) does it hold
/// the `local_device_type` subfield, where barometer is 4. Garmin's official
/// SDKs agree on every value used here:
///
/// - fit-cpp-sdk `src/fit_profile.hpp` L2396 (`FIT_SOURCE_TYPE_LOCAL` 5) and
///   L2405 (`FIT_LOCAL_DEVICE_TYPE_BAROMETER` 4); `src/fit_profile.cpp` L1499
///   (`device_type`, field 1), L1513 (`source_type`, field 25), and L1463–1466
///   (`local_device_type` is active when `source_type == local`);
/// - fit-swift-sdk `Profile/Types/SourceType.swift` L18 (`local = 5`),
///   `Profile/Types/LocalDeviceType.swift` L17 (`barometer = 4`), and
///   `Profile/Mesgs/DeviceInfoMesg.swift` L16 and L30 (field numbers 1 and 25)
///   with L358 (`addMap(refFieldNum: 25, refFieldValue: 5)`).
///
/// A `device_type` of 4 without a local `source_type` is not evidence. The
/// same field then reads through another subfield (`DeviceInfoMesg.swift`
/// L351–356), where 4 is not a barometer: `ble_device_type` 4 is bike speed
/// (`BleDeviceType.swift` L17), `antplus_device_type` defines no 4
/// (`AntplusDeviceType.swift`), `ant_device_type` is a bare number, and a
/// Bluetooth, Wi-Fi or absent source selects no subfield at all.
enum FITAltitudeSensorEvidence {
    static let localSourceType: UInt8 = 5
    static let barometerLocalDeviceType: UInt8 = 4

    static func recordedAltitudeSensor(in deviceInfo: [FITDeviceInfoMessage]) -> RecordedAltitudeSensor {
        let declaresBarometer = deviceInfo.contains { message in
            message.sourceType == localSourceType && message.deviceType == barometerLocalDeviceType
        }
        return declaresBarometer ? .barometric : .unknown
    }
}
