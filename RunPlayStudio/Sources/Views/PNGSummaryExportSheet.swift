import AppKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI
import UniformTypeIdentifiers

/// Configuration sheet for map-aware PNG summary export.
struct PNGSummaryExportSheet: View {
    @Bindable var viewModel: PNGSummaryExportViewModel
    var onDismiss: () -> Void
    var onSaved: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                controls
                    .frame(width: 280, alignment: .topLeading)
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 640)
        .task {
            await viewModel.updateAvailabilityProbe()
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Summary Card")
                    .font(.title2.weight(.semibold))
                Text("Configure map, appearance, and route color before saving a 1200×1600 PNG.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                viewModel.cancel()
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var controls: some View {
        Form {
            Section {
                Toggle("Include Map", isOn: $viewModel.configuration.includeMap)
                    .disabled(!viewModel.hasUsableRoute)
                    .help(viewModel.hasUsableRoute
                          ? "Include a static Apple Maps region with the workout route."
                          : "This workout has no usable GPS route for a map export.")
                    .accessibilityLabel("Include map")
                    .accessibilityHint(viewModel.hasUsableRoute
                                       ? "Adds Apple Maps imagery to the summary card"
                                       : "Unavailable because this workout has no GPS route")

                if !viewModel.hasUsableRoute {
                    Text("No usable GPS route — metrics-only card will be exported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $viewModel.configuration.appearance) {
                    ForEach(PNGSummaryExportAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Export appearance")
            }

            Section("Route Color") {
                Picker("Route Color", selection: $viewModel.configuration.routeColorMode) {
                    ForEach(WorkoutRouteColorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .disabled(!viewModel.configuration.includeMap || !viewModel.hasUsableRoute)
                .accessibilityLabel("Route color mode")

                ForEach(WorkoutRouteColorMode.allCases.filter { $0 != .solid }, id: \.self) { mode in
                    if !viewModel.isModeAvailable(mode) {
                        Text("\(mode.displayName): \(mode.unavailableReason ?? "Unavailable")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if viewModel.configuration.includeMap,
                   !viewModel.isModeAvailable(viewModel.configuration.routeColorMode),
                   viewModel.configuration.routeColorMode != .solid {
                    Text("Selected mode is unavailable for this workout; export will use Solid.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let mapFailure = viewModel.mapFailureMessage {
                Section("Map unavailable") {
                    Text(mapFailure)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Retry") { viewModel.retry() }
                        Button("Export Without Map") { viewModel.exportWithoutMap() }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if viewModel.isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.phase.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Export status \(viewModel.phase.displayName)")
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image = viewModel.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .opacity(viewModel.isGenerating ? 0.55 : 1)
                        .accessibilityLabel(viewModel.previewAccessibilityLabel())
                } else if viewModel.isGenerating {
                    ProgressView("Generating preview…")
                } else {
                    Text("Preview will appear here")
                        .foregroundStyle(.secondary)
                }

                if viewModel.isGenerating, viewModel.previewImage != nil {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            Text("Final output: \(PNGSummaryExportDimensions.width)×\(PNGSummaryExportDimensions.height) pixels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                viewModel.cancel()
                onDismiss()
            }
            Spacer()
            Button("Export PNG") {
                presentSavePanel()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.previewData == nil || viewModel.isGenerating)
            .accessibilityLabel("Export PNG")
            .accessibilityHint("Saves the generated summary card image")
        }
        .padding(20)
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = viewModel.defaultFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await viewModel.save(to: url)
                    onSaved(url.lastPathComponent)
                    onDismiss()
                } catch {
                    viewModel.reportSaveFailure("Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }
}
