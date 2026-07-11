import SwiftUI
import RunPlayCore

/// Shown when no workout is selected, prompting user to import or load a sample.
///
/// Uses a warm gradient backdrop and staggered entrance animation to create
/// an inviting first impression instead of a generic placeholder.
struct EmptyStateView: View {
    var onImport: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Atmospheric gradient backdrop
            gradientBackground

            VStack(spacing: AppDesign.Spacing.xxxLarge) {
                // Hero icon with subtle glow
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 120, height: 120)
                        .shadow(color: AppDesign.primaryBlue.opacity(0.15), radius: 20, y: 8)

                    Image(systemName: "figure.run")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppDesign.primaryBlue, AppDesign.MetricColor.pace],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(appeared ? 1.0 : 0.8)
                .opacity(appeared ? 1.0 : 0.0)

                // Title and description
                VStack(spacing: AppDesign.Spacing.medium) {
                    Text("No Run Selected")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Import a GPX, TCX, FIT, or JSON file\nto visualize your run")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .opacity(appeared ? 1.0 : 0.0)
                .offset(y: appeared ? 0 : 12)

                // CTA button
                Button(action: onImport) {
                    Label("Import File", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, AppDesign.Spacing.xxLarge)
                        .padding(.vertical, AppDesign.Spacing.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .opacity(appeared ? 1.0 : 0.0)
                .offset(y: appeared ? 0 : 16)

                // Supported formats hint
                HStack(spacing: AppDesign.Spacing.small) {
                    ForEach(["GPX", "TCX", "FIT", "JSON"], id: \.self) { format in
                        Text(format)
                            .font(AppDesign.Typography.compactLabel)
                            .padding(.horizontal, AppDesign.Spacing.small)
                            .padding(.vertical, AppDesign.Spacing.xxSmall)
                            .background(AppDesign.panelBackground)
                            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.small))
                    }
                }
                .opacity(appeared ? 1.0 : 0.0)
                .offset(y: appeared ? 0 : 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                AppDesign.primaryBlue.opacity(0.03),
                Color(nsColor: .windowBackgroundColor),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
