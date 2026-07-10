import SwiftUI

struct RouteMapStatusBadge: View {
    let state: RouteMapLoadState

    @ViewBuilder
    var body: some View {
        switch state {
        case .ready:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading map...")
            }
            .font(.caption)
            .padding(8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .unavailable:
            Label("Map unavailable", systemImage: "map")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
