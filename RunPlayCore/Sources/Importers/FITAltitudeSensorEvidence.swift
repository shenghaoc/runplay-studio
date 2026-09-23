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
/// A `device_type` of 4 without a local `source_type` is not evidence: for an
/// ANT+ or Bluetooth source the same number names a different device.
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
