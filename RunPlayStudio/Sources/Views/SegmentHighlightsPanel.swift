import SwiftUI
import RunPlayCore

/// Panel showing detected segments with selection capability.
struct SegmentHighlightsPanel: View {
    let segments: [SegmentHighlight]
    @Binding var selectedSegment: SegmentHighlight?
    var onSelect: ((SegmentHighlight) -> Void)?
    var onClear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Segments")
                    .font(.headline)
                Spacer()
                if selectedSegment != nil {
                    Button("Clear") {
                        selectedSegment = nil
                        onClear?()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if segments.isEmpty {
                Text("No segments detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(segments) { segment in
                            let isSelected = selectedSegment?.id == segment.id
                            Button {
                                selectedSegment = segment
                                onSelect?(segment)
                            } label: {
                                SegmentCard(
                                    segment: segment,
                                    isSelected: isSelected
                                )
                            }
                            .buttonStyle(.plain)
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
struct SegmentCard: View {
    let segment: SegmentHighlight
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: segment.type.icon)
                    .font(.caption2)
                    .foregroundStyle(segmentColor)
                Text(segment.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            Text(segment.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Label(segment.formattedDistance, systemImage: "ruler")
                Label(segment.formattedDuration, systemImage: "clock")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

            if !segment.formattedElevation.isEmpty {
                Label(segment.formattedElevation, systemImage: "mountain.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 120)
        .background(isSelected ? segmentColor.opacity(0.15) : Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? segmentColor : Color.clear, lineWidth: 2)
        )
    }

    private var segmentColor: Color {
        switch segment.type {
        case .fastest400m, .fastest1km: return .blue
        case .slowest1km: return .red
        case .biggestClimb: return .orange
        case .biggestDescent: return .purple
        case .slowdown: return .yellow
        case .custom: return .gray
        }
    }
}
