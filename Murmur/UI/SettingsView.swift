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

            VocabularySettings(controller: controller)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }

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

            Picker("Microphone", selection: $settings.inputDeviceUID) {
                Text("System default").tag("")
                ForEach(controller.inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("System default follows whatever macOS is using, including "
               + "AirPods connecting and disconnecting.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            Picker("Indicator position", selection: $settings.hudPosition) {
                ForEach(HUDPosition.allCases) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .disabled(!settings.showHUD)
            Toggle("Play a sound when recording starts and stops", isOn: $settings.playSounds)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, enabled in
                    applyLaunchAtLogin(enabled)
                }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .task { controller.refreshInputDevices() }
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

// MARK: - Vocabulary

private struct VocabularySettings: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section {
                Text("Words and phrases to listen out for — names, jargon, "
                   + "project nouns, anything the transcriber keeps getting "
                   + "wrong. One per line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $settings.customVocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                LabeledContent("Terms") {
                    Text("\(settings.snapshot.vocabularyTerms.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("This biases recognition toward your words without "
                   + "retraining anything, and stays entirely on-device. "
                   + "Changing it rebuilds the speech session, which takes a "
                   + "moment the next time you dictate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
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

    // Split into sub-views: as one expression this Form grew past what the
    // type-checker will solve in reasonable time.
    var body: some View {
        Form {
            SilenceSection(settings: controller.settings)
            Divider()
            TimingSection(settings: controller.settings)
            Divider()
            HistorySection(controller: controller)
            Divider()
            PasteSafetySection(settings: controller.settings)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct SilenceSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Stop automatically when I stop speaking", isOn: $settings.autoStopOnSilence)

        LabeledContent("Silence before stopping") {
            Stepper("\(settings.silenceTimeoutMilliseconds) ms",
                    value: $settings.silenceTimeoutMilliseconds,
                    in: 500...5000, step: 250)
        }
        .disabled(!settings.autoStopOnSilence)

        Text("Uses Apple's on-device voice activity detection. Applies to "
           + "tap-to-start mode only — when you are holding the key, the key "
           + "decides when to stop.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct TimingSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        LabeledContent("Maximum dictation length") {
            Stepper("\(settings.maxDictationSeconds) s",
                    value: $settings.maxDictationSeconds,
                    in: 10...600, step: 10)
        }

        LabeledContent("Ignore presses shorter than") {
            Stepper("\(settings.minimumDictationMilliseconds) ms",
                    value: $settings.minimumDictationMilliseconds,
                    in: 0...1000, step: 50)
        }

        LabeledContent("Keep listening after release") {
            Stepper("\(settings.tailGraceMilliseconds) ms",
                    value: $settings.tailGraceMilliseconds,
                    in: 0...500, step: 25)
        }
        Text("The microphone delivers audio in ~100 ms blocks and discards "
           + "whatever is mid-block when it stops, so releasing the key on the "
           + "last syllable can clip a word. Murmur waits for that final block "
           + "— usually far less than the limit. Set 0 for lowest latency.")
            .font(.caption)
            .foregroundStyle(.secondary)

        LabeledContent("Restore clipboard after") {
            Stepper("\(settings.pasteRestoreDelayMilliseconds) ms",
                    value: $settings.pasteRestoreDelayMilliseconds,
                    in: 50...2000, step: 50)
        }
        Text("A ceiling, not a fixed wait: Murmur normally restores the moment "
           + "the target app reads the text. Raise it if pastes occasionally "
           + "come out empty.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct HistorySection: View {
    @Bindable var controller: DictationController

    var body: some View {
        @Bindable var settings = controller.settings

        LabeledContent("Keep recent transcripts") {
            Stepper("\(settings.historyLimit)",
                    value: $settings.historyLimit,
                    in: 0...100, step: 5)
        }
        Text("Shown in the menu so a dictation that went somewhere unexpected "
           + "can be copied back. Saved to disk so it survives restarts. "
           + "Set 0 to delete it and keep nothing.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("The file is plain JSON in your Application Support folder, "
           + "readable only by your account and never sent anywhere — but it "
           + "is not encrypted, so it is a running record of what you have "
           + "dictated.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Button("Reveal history file") {
                guard let url = controller.history.storageURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(controller.history.storageURL == nil)

            Button("Delete history now") { controller.history.clear() }
                .disabled(controller.history.records.isEmpty)

            if controller.history.didJustClear {
                Label("Deleted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .transition(.opacity)
            }
        }
    }
}

private struct PasteSafetySection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Only paste into a confirmed text field", isOn: $settings.requireEditableField)
        Text("Uses the Accessibility API to check the focused element first. "
           + "Safer — a stray paste in the Finder duplicates a file — but some "
           + "Electron and terminal apps report their text areas in ways this "
           + "cannot recognise, so the transcript goes to the clipboard instead.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
