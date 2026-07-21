import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Compact, accessible legend for a workout-relative route metric scale.
struct RouteMetricLegendView: View {
    let mode: WorkoutRouteColorMode
    let scale: RouteMetricScale
    var showsNoData: Bool = false
    var coverageFraction: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
            Text("\(mode.displayName) — \(mode.relativeScaleCaption)")
                .font(AppDesign.Typography.compactLabel.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(0..<RouteMetricPalette.policyBucketCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppDesign.RouteMetric.color(mode: mode, bucket: .level(index)))
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: 220)
            .accessibilityHidden(true)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(scale.lowerLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(lowerEndLabel)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppDesign.Spacing.small)
                VStack(alignment: .center, spacing: 1) {
                    Text(scale.medianLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(String(localized: "Median"))
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppDesign.Spacing.small)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(scale.upperLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(upperEndLabel)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220)

            if showsNoData {
                HStack(spacing: AppDesign.Spacing.xSmall) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppDesign.RouteMetric.noData)
                        .frame(width: 14, height: 8)
                    Text(String(localized: "No data"))
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if coverageFraction < 0.92, coverageFraction > 0 {
                Text(coverageText)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var lowerEndLabel: String {
        switch mode {
        case .pace: return String(localized: "Faster")
        case .heartRate: return String(localized: "Lower")
        case .correctedElevation: return String(localized: "Lower")
        case .solid: return ""
        }
    }

    private var upperEndLabel: String {
        switch mode {
        case .pace: return String(localized: "Slower")
        case .heartRate: return String(localized: "Higher")
        case .correctedElevation: return String(localized: "Higher")
        case .solid: return ""
        }
    }

    private var coverageText: String {
        let percent = Int((coverageFraction * 100).rounded())
        switch mode {
        case .heartRate:
            return String(localized: "Heart-rate data covers \(percent)% of route distance.")
        case .correctedElevation:
            return String(localized: "Corrected elevation covers \(percent)% of route distance.")
        case .pace:
            return String(localized: "Valid pace covers \(percent)% of route distance.")
        case .solid:
            return ""
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            String(localized: "\(mode.displayName) legend. \(mode.relativeScaleCaption)."),
            String(localized: "\(lowerEndLabel) \(scale.lowerLabel)."),
            String(localized: "Median \(scale.medianLabel)."),
            String(localized: "\(upperEndLabel) \(scale.upperLabel).")
        ]
        if showsNoData {
            parts.append(String(localized: "Some sections have no metric data."))
        }
        if coverageFraction < 0.92, coverageFraction > 0 {
            parts.append(coverageText)
        }
        return parts.joined(separator: " ")
    }
}
