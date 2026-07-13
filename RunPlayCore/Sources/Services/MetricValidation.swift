import Foundation

/// Validation helpers for workout metrics.
///
/// Contains range checks and safe formatting for metric values
/// that are not specific to geographic distance calculations.
public enum MetricValidation {

    /// Valid heart rate range for filtering outliers (30-230 bpm).
    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Check whether a heart rate value is within the valid range.
    public static func isValidHeartRate(_ bpm: Double) -> Bool {
        bpm.isFinite && validHeartRateRange.contains(bpm)
    }
}

/// Safe display formatters for workout metrics.
///
/// All formatters guard against NaN, infinity, negative values where
/// inappropriate, and nil inputs. Returns a human-readable fallback
/// string instead of crashing or emitting "nan"/"inf".
public enum DisplayFormatter {

    // MARK: - Duration

    /// Format elapsed seconds as HH:MM:SS or MM:SS.
    public static func formatDuration(_ seconds: Double?) -> String {
        guard let value = seconds,
              value.isFinite,
              value >= 0,
              value < Double(Int.max)
        else { return "--:--" }
        let totalSeconds = Int(value)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Format elapsed seconds as MM:SS (no hours).
    public static func formatElapsed(_ seconds: Double?) -> String {
        guard let value = seconds,
              value.isFinite,
              value >= 0,
              value < Double(Int.max)
        else { return "--:--" }
        let totalSeconds = Int(value)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Pace

    /// Format pace in seconds per kilometer as M:SS /km.
    public static func formatPace(_ paceSecondsPerKm: Double?) -> String {
        guard let value = paceSecondsPerKm,
              value.isFinite,
              value > 0,
              value < Double(Int.max)
        else { return "--:-- /km" }
        let mins = Int(value) / 60
        let secs = Int(value) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    /// Format pace in seconds per kilometer as M:SS (no "/km" suffix, for narrow table contexts).
    public static func formatPaceShort(_ paceSecondsPerKm: Double?) -> String {
        guard let value = paceSecondsPerKm,
              value.isFinite,
              value > 0,
              value < Double(Int.max)
        else { return "--:--" }
        let mins = Int(value) / 60
        let secs = Int(value) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Distance

    /// Format distance in meters as km with 2 decimal places.
    public static func formatDistanceKm(_ meters: Double?) -> String {
        guard let value = meters, value.isFinite, value >= 0 else { return "--- km" }
        return String(format: "%.2f km", value / 1000.0)
    }

    /// Format distance in meters, showing km for >= 1000m and m otherwise.
    public static func formatDistance(_ meters: Double?) -> String {
        guard let value = meters, value.isFinite, value >= 0 else { return "---" }
        if value >= 1000 {
            return String(format: "%.1f km", value / 1000)
        }
        return String(format: "%.0f m", value)
    }

    // MARK: - Elevation

    /// Format elevation in meters.
    public static func formatElevation(_ meters: Double?) -> String {
        guard let value = meters, value.isFinite else { return "--- m" }
        return String(format: "%.0f m", value)
    }

    /// Format elevation delta with +/- sign.
    public static func formatElevationDelta(_ meters: Double?) -> String {
        guard let value = meters, value.isFinite else { return "" }
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", value)) m"
    }

    // MARK: - Heart Rate

    /// Format heart rate in bpm.
    public static func formatHeartRate(_ bpm: Double?) -> String {
        guard let value = bpm, value.isFinite else { return "--- bpm" }
        return String(format: "%.0f bpm", value)
    }

    // MARK: - Speed

    /// Format speed in meters per second.
    public static func formatSpeed(_ mps: Double?) -> String {
        guard let value = mps, value.isFinite, value >= 0 else { return "--- m/s" }
        return String(format: "%.1f m/s", value)
    }

    /// Format speed as km/h.
    public static func formatSpeedKmh(_ mps: Double?) -> String {
        guard let value = mps, value.isFinite, value >= 0 else { return "--- km/h" }
        return String(format: "%.1f km/h", value * 3.6)
    }

    // MARK: - Cadence

    /// Format cadence in steps per minute.
    public static func formatCadence(_ spm: Double?) -> String {
        guard let value = spm, value.isFinite, value >= 0 else { return "--- spm" }
        return String(format: "%.0f spm", value)
    }

    // MARK: - Numbers

    /// Safely format a Double for CSV/display, returning empty string for non-finite values.
    public static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded() && abs(value) < 1e10 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    /// Safely format an optional Double for CSV/display.
    public static func formatOptionalNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return formatNumber(value)
    }

    /// Format a signed duration delta without unsafe conversion of huge finite
    /// values. Positive and negative labels describe the primary value.
    public static func formatSignedDurationDelta(
        _ delta: Double?,
        suffix: String? = nil,
        positiveLabel: String = "slower",
        negativeLabel: String = "faster"
    ) -> String {
        guard let delta,
              delta.isFinite,
              abs(delta) < Double(Int.max)
        else {
            return "N/A"
        }

        let suffixText = suffix.map { " \($0)" } ?? ""
        if abs(delta) < 0.5 {
            return "0:00\(suffixText) even"
        }

        let rounded = Int(abs(delta).rounded())
        let minutes = rounded / 60
        let seconds = rounded % 60
        let sign = delta > 0 ? "+" : "-"
        let label = delta > 0 ? positiveLabel : negativeLabel
        return "\(sign)\(minutes):\(String(format: "%02d", seconds))\(suffixText) \(label)"
    }
}
