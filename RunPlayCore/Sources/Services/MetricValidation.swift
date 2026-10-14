import Foundation

/// Validation helpers for workout metrics.
///
/// Contains range checks and safe formatting for metric values
/// that are not specific to geographic distance calculations.
public enum MetricValidation {

    /// Valid heart rate range for filtering outliers (30-230 bpm).
    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Valid running cadence range in steps per minute. FIT and TCX cadence
    /// fields are byte-sized; the small margin keeps validation format-neutral.
    public static let validCadenceRange: ClosedRange<Double> = 0...300

    /// Valid running power range in watts (0–5,000 W covers running meters
    /// and cycling-scale headroom; negative values are sensor noise).
    public static let validPowerRange: ClosedRange<Double> = 0...5_000

    /// Valid ground contact time range in milliseconds.
    public static let validGroundContactTimeRange: ClosedRange<Double> = 0...1_000

    /// Valid vertical oscillation range in millimeters.
    public static let validVerticalOscillationRange: ClosedRange<Double> = 0...100

    /// Valid vertical ratio range in percent.
    public static let validVerticalRatioRange: ClosedRange<Double> = 0...100

    /// Valid stance time balance range in percent.
    public static let validStanceTimeBalanceRange: ClosedRange<Double> = 0...100

    /// Valid step length range in meters.
    public static let validStepLengthRange: ClosedRange<Double> = 0...5

    /// Check whether a heart rate value is within the valid range.
    public static func isValidHeartRate(_ bpm: Double) -> Bool {
        bpm.isFinite && validHeartRateRange.contains(bpm)
    }

    /// Check whether a cadence value is finite and physically representable by
    /// the supported source formats.
    public static func isValidCadence(_ stepsPerMinute: Double) -> Bool {
        stepsPerMinute.isFinite && validCadenceRange.contains(stepsPerMinute)
    }

    /// Check whether a power value is finite and inside the plausible
    /// running-power range.
    public static func isValidPower(_ watts: Double) -> Bool {
        watts.isFinite && validPowerRange.contains(watts)
    }

    /// Check whether a running-dynamics value is finite and plausible.
    public static func isValidGroundContactTime(_ milliseconds: Double) -> Bool {
        milliseconds.isFinite && validGroundContactTimeRange.contains(milliseconds)
    }

    /// Check whether a running-dynamics value is finite and plausible.
    public static func isValidVerticalOscillation(_ millimeters: Double) -> Bool {
        millimeters.isFinite && validVerticalOscillationRange.contains(millimeters)
    }

    /// Check whether a running-dynamics value is finite and plausible.
    public static func isValidVerticalRatio(_ percent: Double) -> Bool {
        percent.isFinite && validVerticalRatioRange.contains(percent)
    }

    /// Check whether a running-dynamics value is finite and plausible.
    public static func isValidStanceTimeBalance(_ percent: Double) -> Bool {
        percent.isFinite && validStanceTimeBalanceRange.contains(percent)
    }

    /// Check whether a running-dynamics value is finite and plausible.
    public static func isValidStepLength(_ meters: Double) -> Bool {
        meters.isFinite && validStepLengthRange.contains(meters)
    }
}

/// Safe display formatters for workout metrics.
///
/// All formatters guard against NaN, infinity, negative values where
/// inappropriate, and nil inputs. Returns a human-readable fallback
/// string instead of crashing or emitting "nan"/"inf".
///
/// Display text follows a locale: numbers, decimal separators, and unit
/// symbols come from Foundation's measurement and number format styles, so
/// "5.00 km" reads "5.00公里" in Simplified Chinese and "5,00 km" in German.
/// `locale` defaults to the app's current locale; exports and tests may pin
/// one. Units Foundation does not model — beats and steps per minute — come
/// from Core's String Catalog. Clock-style durations and paces (`1:02:05`,
/// `5:30`) are locale-neutral and stay digit-colon-digit everywhere.
///
/// Values round half away from zero ("10.05 km" shows "10.1 km"), the rule
/// readers expect; Foundation's default would round half to even.
///
/// Swift Foundation on Linux lacks the measurement format styles, so there the
/// formatters keep their original fixed English output. `formatNumber` is the
/// locale-invariant CSV number format on every platform.
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

    /// Format pace in seconds per kilometer as M:SS followed by the locale's
    /// per-kilometre suffix ("5:30 /km", "5:30 /公里").
    public static func formatPace(_ paceSecondsPerKm: Double?, locale: Locale? = nil) -> String {
        "\(formatPaceShort(paceSecondsPerKm)) \(perKilometerSuffix(locale: locale))"
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

    /// The suffix that turns a M:SS value into a pace: "/" plus the locale's
    /// abbreviated kilometre symbol ("/km", "/公里").
    public static func perKilometerSuffix(locale: Locale? = nil) -> String {
        "/" + unitSymbol(UnitLength.kilometers, fallback: "km", locale: locale)
    }

    /// The locale's symbol for one of the app's unit tokens ("km", "m",
    /// "s/km", "bpm", "W", …), for axis titles and spoken chart summaries.
    ///
    /// The tokens themselves are identifiers that metric code matches on, so
    /// they stay English; only what is shown or spoken is localized. Unknown
    /// tokens are returned unchanged.
    public static func unitSymbol(forToken token: String, locale: Locale? = nil) -> String {
        switch token {
        case "km": return unitSymbol(UnitLength.kilometers, fallback: token, locale: locale)
        case "m": return unitSymbol(UnitLength.meters, fallback: token, locale: locale)
        case "mm": return unitSymbol(UnitLength.millimeters, fallback: token, locale: locale)
        case "ms": return unitSymbol(UnitDuration.milliseconds, fallback: token, locale: locale)
        case "W": return unitSymbol(UnitPower.watts, fallback: token, locale: locale)
        case "m/s": return unitSymbol(UnitSpeed.metersPerSecond, fallback: token, locale: locale)
        case "km/h": return unitSymbol(UnitSpeed.kilometersPerHour, fallback: token, locale: locale)
        case "s/km":
            return unitSymbol(UnitDuration.seconds, fallback: "s", locale: locale)
                + perKilometerSuffix(locale: locale)
        case "bpm": return coreLocalized("bpm", locale: locale)
        case "spm": return coreLocalized("spm", locale: locale)
        default: return token
        }
    }

    // MARK: - Distance

    /// Format distance in meters as km with 2 decimal places.
    public static func formatDistanceKm(_ meters: Double?, locale: Locale? = nil) -> String {
        guard let value = meters, value.isFinite, value >= 0 else {
            return placeholder(UnitLength.kilometers, fallback: "--- km", locale: locale)
        }
        return measurement(value / 1000.0, UnitLength.kilometers, fractionDigits: 2, fallbackFormat: "%.2f km", locale: locale)
    }

    /// Format distance in meters as km with `fractionDigits` decimals, signed
    /// ("+1.23 km") when `signed` is true. Negative values are allowed.
    public static func formatKilometers(
        _ meters: Double?,
        fractionDigits: Int,
        signed: Bool = false,
        locale: Locale? = nil
    ) -> String {
        guard let value = meters, value.isFinite else {
            return placeholder(UnitLength.kilometers, fallback: "--- km", locale: locale)
        }
        #if canImport(Darwin)
        return measurement(value / 1000.0, UnitLength.kilometers, fractionDigits: fractionDigits, signed: signed, locale: locale)
        #else
        return String(format: "%\(signed ? "+" : "").\(fractionDigits)f km", value / 1000.0)
        #endif
    }

    /// Format a length in whole (or `fractionDigits`) meters, signed when
    /// `signed` is true ("12 m", "+12 m", "12米"). Negative values are allowed.
    public static func formatMeters(
        _ meters: Double?,
        fractionDigits: Int = 0,
        signed: Bool = false,
        locale: Locale? = nil
    ) -> String {
        guard let value = meters, value.isFinite else {
            return placeholder(UnitLength.meters, fallback: "--- m", locale: locale)
        }
        #if canImport(Darwin)
        return measurement(value, UnitLength.meters, fractionDigits: fractionDigits, signed: signed, locale: locale)
        #else
        return String(format: "%\(signed ? "+" : "").\(fractionDigits)f m", value)
        #endif
    }

    /// A plain number with `fractionDigits` decimals in the locale's digits
    /// and separators ("1.23", "1,23"), for values whose unit is written
    /// once elsewhere ("1.23 / 5.00 km").
    public static func formatDecimal(_ value: Double, fractionDigits: Int, locale: Locale? = nil) -> String {
        guard value.isFinite else { return "---" }
        #if canImport(Darwin)
        return value.formatted(
            .number.precision(.fractionLength(fractionDigits)).rounded(rule: .toNearestOrAwayFromZero)
                .locale(locale ?? .autoupdatingCurrent)
        )
        #else
        return String(format: "%.\(fractionDigits)f", value)
        #endif
    }

    /// Format distance in meters, showing km for >= 1000m and m otherwise.
    public static func formatDistance(_ meters: Double?, locale: Locale? = nil) -> String {
        guard let value = meters, value.isFinite, value >= 0 else { return "---" }
        if value >= 1000 {
            return measurement(value / 1000, UnitLength.kilometers, fractionDigits: 1, fallbackFormat: "%.1f km", locale: locale)
        }
        return measurement(value, UnitLength.meters, fractionDigits: 0, fallbackFormat: "%.0f m", locale: locale)
    }

    // MARK: - Elevation

    /// Format elevation in meters.
    public static func formatElevation(_ meters: Double?, locale: Locale? = nil) -> String {
        guard let value = meters, value.isFinite else {
            return placeholder(UnitLength.meters, fallback: "--- m", locale: locale)
        }
        return measurement(value, UnitLength.meters, fractionDigits: 0, fallbackFormat: "%.0f m", locale: locale)
    }

    /// Format elevation delta with +/- sign.
    public static func formatElevationDelta(_ meters: Double?, locale: Locale? = nil) -> String {
        guard let value = meters, value.isFinite else { return "" }
        #if canImport(Darwin)
        return measurement(value, UnitLength.meters, fractionDigits: 0, signed: true, locale: locale)
        #else
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", value)) m"
        #endif
    }

    // MARK: - Heart Rate

    /// Format heart rate in beats per minute ("146 bpm", "146 次/分").
    public static func formatHeartRate(_ bpm: Double?, locale: Locale? = nil) -> String {
        let number = bpm.flatMap { $0.isFinite ? wholeNumber($0, locale: locale) : nil } ?? "---"
        return coreLocalized("\(number) bpm", locale: locale)
    }

    /// Format a signed heart-rate difference ("+5 bpm", "-3 次/分").
    public static func formatHeartRateDelta(_ bpm: Double?, locale: Locale? = nil) -> String {
        guard let value = bpm, value.isFinite else {
            return coreLocalized("\("---") bpm", locale: locale)
        }
        #if canImport(Darwin)
        let number = value.formatted(
            .number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)
                .sign(strategy: .always()).locale(locale ?? .autoupdatingCurrent)
        )
        #else
        let number = String(format: "%+.0f", value)
        #endif
        return coreLocalized("\(number) bpm", locale: locale)
    }

    // MARK: - Speed

    /// Format speed in meters per second.
    public static func formatSpeed(_ mps: Double?, locale: Locale? = nil) -> String {
        guard let value = mps, value.isFinite, value >= 0 else {
            return placeholder(UnitSpeed.metersPerSecond, fallback: "--- m/s", locale: locale)
        }
        return measurement(value, UnitSpeed.metersPerSecond, fractionDigits: 1, fallbackFormat: "%.1f m/s", locale: locale)
    }

    /// Format speed as km/h.
    public static func formatSpeedKmh(_ mps: Double?, locale: Locale? = nil) -> String {
        guard let value = mps, value.isFinite, value >= 0 else {
            return placeholder(UnitSpeed.kilometersPerHour, fallback: "--- km/h", locale: locale)
        }
        return measurement(value * 3.6, UnitSpeed.kilometersPerHour, fractionDigits: 1, fallbackFormat: "%.1f km/h", locale: locale)
    }

    // MARK: - Cadence

    /// Format cadence in steps per minute ("180 spm", "180 步/分").
    public static func formatCadence(_ spm: Double?, locale: Locale? = nil) -> String {
        let number = spm.flatMap { $0.isFinite && $0 >= 0 ? wholeNumber($0, locale: locale) : nil } ?? "---"
        return coreLocalized("\(number) spm", locale: locale)
    }

    // MARK: - Power

    /// Format running power in watts.
    public static func formatPower(_ watts: Double?, locale: Locale? = nil) -> String {
        guard let value = watts, value.isFinite, value >= 0 else {
            return placeholder(UnitPower.watts, fallback: "--- W", locale: locale)
        }
        return measurement(value, UnitPower.watts, fractionDigits: 0, fallbackFormat: "%.0f W", locale: locale)
    }

    // MARK: - Running dynamics

    /// Format ground contact time in milliseconds.
    public static func formatGroundContactTime(_ milliseconds: Double?, locale: Locale? = nil) -> String {
        guard let value = milliseconds, value.isFinite, value >= 0 else {
            return placeholder(UnitDuration.milliseconds, fallback: "--- ms", locale: locale)
        }
        return measurement(value, UnitDuration.milliseconds, fractionDigits: 0, fallbackFormat: "%.0f ms", locale: locale)
    }

    /// Format vertical oscillation in millimeters.
    public static func formatVerticalOscillation(_ millimeters: Double?, locale: Locale? = nil) -> String {
        guard let value = millimeters, value.isFinite, value >= 0 else {
            return placeholder(UnitLength.millimeters, fallback: "--- mm", locale: locale)
        }
        return measurement(value, UnitLength.millimeters, fractionDigits: 1, fallbackFormat: "%.1f mm", locale: locale)
    }

    /// Format vertical ratio in percent.
    public static func formatVerticalRatio(_ percent: Double?, locale: Locale? = nil) -> String {
        formatPercent(percent, locale: locale)
    }

    /// Format stance time balance in percent.
    public static func formatStanceTimeBalance(_ percent: Double?, locale: Locale? = nil) -> String {
        formatPercent(percent, locale: locale)
    }

    /// Format step length in meters.
    public static func formatStepLength(_ meters: Double?, locale: Locale? = nil) -> String {
        guard let value = meters, value.isFinite, value >= 0 else {
            return placeholder(UnitLength.meters, fallback: "--- m", locale: locale)
        }
        return measurement(value, UnitLength.meters, fractionDigits: 2, fallbackFormat: "%.2f m", locale: locale)
    }

    // MARK: - Numbers

    /// Safely format a Double for CSV/display, returning empty string for non-finite values.
    ///
    /// Locale-invariant on purpose: CSV exports are a machine-readable schema.
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
    ///
    /// `suffix` follows the clock value ("+0:12 /km slower"); pass
    /// `perKilometerSuffix()` for pace deltas. Labels default to Core's
    /// localized "slower"/"faster".
    public static func formatSignedDurationDelta(
        _ delta: Double?,
        suffix: String? = nil,
        positiveLabel: String? = nil,
        negativeLabel: String? = nil,
        locale: Locale? = nil
    ) -> String {
        guard let delta,
              delta.isFinite,
              abs(delta) < Double(Int.max)
        else {
            return coreLocalized("N/A", locale: locale)
        }

        let suffixText = suffix.map { " \($0)" } ?? ""
        if abs(delta) < 0.5 {
            let value = "0:00\(suffixText)"
            return coreLocalized("\(value) even", locale: locale)
        }

        let rounded = Int(abs(delta).rounded())
        let minutes = rounded / 60
        let seconds = rounded % 60
        let sign = delta > 0 ? "+" : "-"
        let value = "\(sign)\(minutes):\(String(format: "%02d", seconds))\(suffixText)"
        let label = delta > 0
            ? positiveLabel ?? coreLocalized("slower", locale: locale)
            : negativeLabel ?? coreLocalized("faster", locale: locale)
        // Value, then the localized word for its direction: "+0:12 slower",
        // "+0:12 较慢".
        return "\(value) \(label)"
    }

    // MARK: - Locale-aware building blocks

    /// Percent with one decimal ("7.5%").
    private static func formatPercent(_ percent: Double?, locale: Locale?) -> String {
        guard let value = percent, value.isFinite, value >= 0 else { return "--- %" }
        #if canImport(Darwin)
        return (value / 100).formatted(
            .percent.precision(.fractionLength(1)).rounded(rule: .toNearestOrAwayFromZero)
                .locale(locale ?? .autoupdatingCurrent)
        )
        #else
        return String(format: "%.1f %%", value)
        #endif
    }

    /// A whole number in the locale's digits and grouping ("146", "1,234").
    private static func wholeNumber(_ value: Double, locale: Locale?) -> String {
        #if canImport(Darwin)
        return value.formatted(
            .number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)
                .locale(locale ?? .autoupdatingCurrent)
        )
        #else
        return String(format: "%.0f", value)
        #endif
    }

    /// A measurement with a fixed number of fraction digits and the locale's
    /// abbreviated unit ("5.00 km", "5.00公里", "12公尺").
    private static func measurement<UnitType: Dimension>(
        _ value: Double,
        _ unit: UnitType,
        fractionDigits: Int,
        signed: Bool = false,
        fallbackFormat: String = "",
        locale: Locale?
    ) -> String {
        #if canImport(Darwin)
        var number = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(fractionDigits))
            .rounded(rule: .toNearestOrAwayFromZero)
        if signed {
            number = number.sign(strategy: .always())
        }
        return Measurement(value: value, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: number)
                .locale(locale ?? .autoupdatingCurrent)
        )
        #else
        return String(format: fallbackFormat, value)
        #endif
    }

    /// The locale's placeholder for a missing measurement: its unit pattern
    /// with the number replaced by "---" ("--- km", "---公里").
    private static func placeholder<UnitType: Dimension>(
        _ unit: UnitType,
        fallback: String,
        locale: Locale?
    ) -> String {
        #if canImport(Darwin)
        let resolved = locale ?? .autoupdatingCurrent
        let zero = Measurement(value: 0, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(resolved)
        )
        let digit = 0.formatted(.number.locale(resolved))
        guard let range = zero.range(of: digit) else { return fallback }
        return zero.replacingCharacters(in: range, with: "---")
        #else
        return fallback
        #endif
    }

    /// The locale's abbreviated symbol for `unit` ("km", "公里").
    private static func unitSymbol<UnitType: Dimension>(
        _ unit: UnitType,
        fallback: String,
        locale: Locale?
    ) -> String {
        #if canImport(Darwin)
        let resolved = locale ?? .autoupdatingCurrent
        let zero = Measurement(value: 0, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(resolved)
        )
        let digit = 0.formatted(.number.locale(resolved))
        guard let range = zero.range(of: digit) else { return fallback }
        let symbol = zero.replacingCharacters(in: range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return symbol.isEmpty ? fallback : symbol
        #else
        return fallback
        #endif
    }
}
