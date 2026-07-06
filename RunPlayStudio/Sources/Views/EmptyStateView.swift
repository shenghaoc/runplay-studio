import SwiftUI
import RunPlayCore

/// Shown when no workout is selected, prompting user to import or load a sample.
struct EmptyStateView: View {
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.run")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No Run Selected")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Import a GPX, TCX, or JSON file to visualize your run in 3D")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button(action: onImport) {
                    Label("Import File", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
