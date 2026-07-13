import SwiftUI
import RunPlayCore

/// Shown when no workout is selected, prompting user to import or load a sample.
///
/// Uses a warm gradient backdrop and staggered entrance animation to create
/// an inviting first impression instead of a generic placeholder.
struct EmptyStateView: View {
    var onImport: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .font(AppDesign.Typography.emptyStateIcon)
                        .foregroundStyle(AppDesign.primaryBlue)
                }
                .scaleEffect(appeared ? 1.0 : 0.8)
                .opacity(appeared ? 1.0 : 0.0)

                // Title and description
                VStack(spacing: AppDesign.Spacing.medium) {
                    Text("No Run Selected")
                        .font(AppDesign.Typography.heading2)

                    Text("Import a GPX, TCX, FIT, or JSON file\nto visualize your run")
                        .font(AppDesign.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .opacity(appeared ? 1.0 : 0.0)
                .offset(y: appeared ? 0 : 12)

                // CTA button
                Button(action: onImport) {
                    Label("Import File", systemImage: "doc.badge.plus")
                        .font(AppDesign.Typography.bodySemibold)
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
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                    appeared = true
                }
            }
        }
    }

    private var gradientBackground: some View {
#if os(macOS)
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
#else
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                AppDesign.primaryBlue.opacity(0.03),
                Color(uiColor: .systemBackground),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
#endif
    }
}
