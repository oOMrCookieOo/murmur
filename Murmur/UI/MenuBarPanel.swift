import SwiftUI

/// The panel shown when the menu-bar icon is clicked.
struct MenuBarPanel: View {
    @Bindable var controller: DictationController
    @Environment(\.openSettings) private var openSettings

    private var settings: AppSettings { controller.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)

            if !controller.permissions.missingCritical.isEmpty {
                permissionsWarning
                Divider().padding(.vertical, 10)
            }

            modelSection

            deliverySection
            Divider().padding(.vertical, 10)

            footer
        }
        .padding(14)
        .frame(width: 290)
        .task { controller.permissions.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Murmur").font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(controller.phase.isRecording ? .red : .secondary)
            }
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text(controller.permissions.missingCritical.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open Settings…") { openSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch controller.modelState {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 5) {
                Text("Downloading speech model…").font(.caption)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
            Divider().padding(.vertical, 10)

        case .notInstalled:
            VStack(alignment: .leading, spacing: 5) {
                Text("Speech model not installed").font(.caption)
                Button("Download \(settings.localeIdentifier)") {
                    Task { await controller.downloadModel() }
                }
                .font(.caption)
            }
            Divider().padding(.vertical, 10)

        case .unsupported:
            Label("\(settings.localeIdentifier) is not supported on this Mac",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            Divider().padding(.vertical, 10)

        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
            Divider().padding(.vertical, 10)

        case .installed, .unknown:
            EmptyView()
        }
    }

    private var deliverySection: some View {
        // A local `@Bindable` is how you get bindings to an @Observable object
        // reached through a `let` property.
        @Bindable var bindable = controller.settings

        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $bindable.deliveryMode) {
                Text("Paste at cursor").tag(DeliveryMode.pasteAtCursor)
                Text("Clipboard only").tag(DeliveryMode.clipboardOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Strip filler words", isOn: $bindable.stripFillers)
                .toggleStyle(.checkbox)
                .font(.callout)

            Toggle("Clean up with Apple Intelligence",
                   isOn: $bindable.polishWithAppleIntelligence)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    // MARK: - Copy

    private var statusText: String {
        switch controller.phase {
        case .idle:          return controller.modelState.isReady ? "Ready" : "Setting up"
        case .listening:     return "Listening"
        case .finalizing:    return "Transcribing"
        case .polishing:     return "Cleaning up"
        case .delivering:    return "Pasting"
        case .finished:      return "Done"
        }
    }

    private var hintText: String {
        switch settings.activationMode {
        case .pushToTalk:
            return "Hold \(settings.triggerKey.displayName) to dictate."
        case .toggle:
            return "Tap \(settings.triggerKey.displayName) to start and stop."
        }
    }
}
