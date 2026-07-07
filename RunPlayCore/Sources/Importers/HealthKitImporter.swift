import Foundation

/// Placeholder for future Apple Health / HealthKit workout import.
///
/// HealthKit is available on macOS but requires careful permission handling.
/// This importer will be implemented after researching macOS HealthKit capabilities.
public struct HealthKitImporter {

    public init() {}
    public static var isAvailable: Bool {
        // HealthKit is available on macOS 13+ but workout access is limited
        // compared to iOS. Research needed before implementation.
        false
    }

    public static var statusMessage: String {
        "HealthKit import is not yet available. Use file import (JSON, GPX) instead."
    }
}
