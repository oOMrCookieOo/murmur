import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var controller: DictationController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }

            SpeechSettings(controller: controller)
                .tabItem { Label("Speech", systemImage: "waveform") }

            CleanupSettings(controller: controller)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }

            PermissionsSettings(permissions: controller.permissions, controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            AdvancedSettings(controller: controller)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Picker("Trigger key", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            Text("Held down while you speak. Modifier keys only, so it never "
               + "interferes with typing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Activation", selection: $settings.activationMode) {
                ForEach(ActivationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Transcript goes to", selection: $settings.deliveryMode) {
                ForEach(DeliveryMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Insert a space before", selection: $settings.spacingMode) {
                ForEach(SpacingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text("Stops back-to-back dictations running together. "
               + "\"Only when needed\" asks the app where the cursor is and "
               + "adds a space only if something is already there.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Show the floating indicator", isOn: $settings.showHUD)
            Toggle("Play a sound when recording starts and stops", isOn: $settings.playSounds)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, enabled in
                    applyLaunchAtLogin(enabled)
                }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Only works for a real, signed .app bundle. Running the binary
            // directly out of a build directory will land here.
            Log.app.error("Launch at login failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Picker("Language", selection: $settings.localeIdentifier) {
                ForEach(controller.supportedLocales, id: \.identifier) { locale in
                    Text(displayName(for: locale)).tag(locale.identifier(.bcp47))
                }
            }
            .disabled(controller.supportedLocales.isEmpty)

            LabeledContent("Model") { modelStatus }

            if case .notInstalled = controller.modelState {
                Button("Download model") {
                    Task { await controller.downloadModel() }
                }
            }

            Section {
                Text("Transcription runs entirely on this Mac using Apple's "
                   + "SpeechAnalyzer. Audio never leaves the device and Murmur "
                   + "makes no network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch controller.modelState {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        case .notInstalled:
            Text("Not downloaded").foregroundStyle(.secondary)
        case .unsupported:
            Label("Not supported", systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .unknown:
            ProgressView().controlSize(.small)
        }
    }

    private func displayName(for locale: Locale) -> String {
        let id = locale.identifier(.bcp47)
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? id
    }
}

// MARK: - Cleanup

private struct CleanupSettings: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section {
                Toggle("Strip filler words", isOn: $settings.stripFillers)
                Text("Removes standalone \"um\", \"uh\", \"erm\" and similar. "
                   + "A plain text substitution — instant, and it cannot invent words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up with Apple Intelligence",
                       isOn: $settings.polishWithAppleIntelligence)
                Text("Fixes capitalisation and punctuation using the on-device "
                   + "foundation model. Runs locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Time limit") {
                    Stepper(
                        "\(settings.polishTimeoutMilliseconds) ms",
                        value: $settings.polishTimeoutMilliseconds,
                        in: 200...5000,
                        step: 100
                    )
                }
                .disabled(!settings.polishWithAppleIntelligence)
            }

            Section {
                Text("Cleanup is never allowed to lose your words. If the model "
                   + "is unavailable, times out, hits its output limit, or "
                   + "returns something too different from what you said, "
                   + "Murmur pastes the raw transcript instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @Bindable var permissions: PermissionsModel
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            row(
                title: "Microphone",
                detail: "Required to hear you.",
                granted: permissions.microphone.isGranted,
                action: { Task { await permissions.requestMicrophone() } },
                pane: .microphone
            )

            row(
                title: "Accessibility",
                detail: "Required to paste into other apps.",
                granted: permissions.accessibility,
                action: { permissions.requestAccessibility() },
                pane: .accessibility
            )

            row(
                title: "Input Monitoring",
                detail: "Required to notice the trigger key while other apps are focused.",
                granted: permissions.inputMonitoring,
                action: { permissions.requestInputMonitoring() },
                pane: .inputMonitoring
            )

            Section {
                Button("Re-check and restart the key listener") {
                    permissions.refresh()
                    controller.retryHotkeyMonitor()
                }
                Text("macOS does not notify apps when permissions change. After "
                   + "granting one, use this to pick it up without relaunching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .task { permissions.refresh() }
    }

    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void,
        pane: PrivacyPane
    ) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    HStack(spacing: 8) {
                        Button("Grant", action: action)
                        Button("Open…") { PermissionsModel.open(pane) }
                    }
                }
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            LabeledContent("Maximum dictation length") {
                Stepper(
                    "\(settings.maxDictationSeconds) s",
                    value: $settings.maxDictationSeconds,
                    in: 10...600,
                    step: 10
                )
            }
            Text("Recording stops automatically at this point and the audio "
               + "captured so far is transcribed, so a stuck key cannot record forever.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Ignore presses shorter than") {
                Stepper(
                    "\(settings.minimumDictationMilliseconds) ms",
                    value: $settings.minimumDictationMilliseconds,
                    in: 0...1000,
                    step: 50
                )
            }

            LabeledContent("Restore clipboard after") {
                Stepper(
                    "\(settings.pasteRestoreDelayMilliseconds) ms",
                    value: $settings.pasteRestoreDelayMilliseconds,
                    in: 50...2000,
                    step: 50
                )
            }
            Text("How long the target app gets to read the clipboard before "
               + "Murmur puts your previous contents back. Raise it if pastes "
               + "occasionally come out empty.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Only paste into a confirmed text field",
                   isOn: $settings.requireEditableField)
            Text("Uses the Accessibility API to check the focused element first. "
               + "Safer, but some Electron and terminal apps report their text "
               + "areas in ways this cannot recognise, so the transcript would "
               + "go to the clipboard instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
