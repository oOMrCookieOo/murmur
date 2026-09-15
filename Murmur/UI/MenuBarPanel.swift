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

            if controller.settings.historyLimit > 0 {
                Divider().padding(.vertical, 10)
                historySection
            }

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

            if let median = controller.medianLatencyMilliseconds,
               let last = controller.lastLatencyMilliseconds {
                Text("Key-up to paste: \(last) ms, median \(median) ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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

    /// Recent transcripts, so a dictation that landed somewhere unexpected is
    /// recoverable rather than gone.
    ///
    /// Always shown, including when empty. Hiding it until the first dictation
    /// meant there was no way to discover the feature existed, or to tell
    /// "nothing recorded yet" apart from "this is broken".
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !controller.history.records.isEmpty {
                    Button("Clear") { controller.history.clear() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if controller.history.records.isEmpty {
                Text("Nothing yet — your dictations will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(controller.history.records.prefix(5)) { record in
                Button {
                    controller.history.copyToClipboard(record)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(record.preview)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to copy — \(record.destination ?? "unknown app")")
            }
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
