import SwiftUI
import RunPlayCore

/// Panel showing detected segments with selection capability.
///
/// Uses pill-shaped segment cards with subtle color coding and
/// a smooth selection animation for a polished feel.
struct SegmentHighlightsPanel: View {
    let segments: [SegmentHighlight]
    @Binding var selectedSegment: SegmentHighlight?
    var onSelect: ((SegmentHighlight) -> Void)?
    var onClear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack {
                Text("Segments")
                    .font(AppDesign.Typography.sectionHeadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedSegment != nil {
                    Button("Clear") {
                        selectedSegment = nil
                        onClear?()
                    }
                    .font(AppDesign.Typography.compactMetric)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }

            if segments.isEmpty {
                Text("No segments detected")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, AppDesign.Spacing.xSmall)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppDesign.Spacing.small) {
                        ForEach(segments) { segment in
                            let isSelected = selectedSegment?.id == segment.id
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedSegment = segment
                                }
                                onSelect?(segment)
                            } label: {
                                SegmentCard(
                                    segment: segment,
                                    isSelected: isSelected
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(segment.title)
                            .accessibilityValue("\(segment.subtitle), \(segment.formattedDistance), \(segment.formattedDuration)")
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                            .help(isSelected ? "Selected segment" : "Select segment")
                        }
                    }
                }
            }
        }
    }
}

/// Card displaying a single segment highlight.
///
/// Uses a compact pill layout with an accent-colored leading edge
/// and subtle background treatment for selection state.
struct SegmentCard: View {
    let segment: SegmentHighlight
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            HStack(spacing: AppDesign.Spacing.xxSmall) {
                Image(systemName: segment.type.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(segmentColor)
                Text(segment.title)
                    .font(AppDesign.Typography.compactMetric)
                    .lineLimit(1)
            }

            Text(segment.subtitle)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)

            HStack(spacing: AppDesign.Spacing.small) {
                Label(segment.formattedDistance, systemImage: "ruler")
                Label(segment.formattedDuration, systemImage: "clock")
                if !segment.formattedElevation.isEmpty {
                    Label(segment.formattedElevation, systemImage: "mountain.2")
                }
            }
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, AppDesign.Spacing.medium)
        .padding(.vertical, AppDesign.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.Radius.medium)
                .fill(isSelected ? segmentColor.opacity(0.1) : AppDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppDesign.Radius.medium)
                .strokeBorder(
                    isSelected ? segmentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private var segmentColor: Color {
        switch segment.type {
        case .fastest400m, .fastest1km: return AppDesign.MetricColor.pace
        case .slowest1km: return AppDesign.MetricColor.heartRate
        case .biggestClimb: return AppDesign.MetricColor.elevation
        case .biggestDescent: return AppDesign.softPurple
        case .slowdown: return AppDesign.warmYellow
        case .custom: return .secondary
        }
    }
}
