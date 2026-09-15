import AppKit
import Foundation
import Observation

/// Orchestrates one dictation from key-down to pasted text.
///
/// The pipeline, in the order the user experiences it:
///
///     key down → remember frontmost app → show HUD → open mic
///     key up   → finalise transcript → optional cleanup
///              → snapshot clipboard → paste → restore clipboard
///
/// Everything here runs on the main actor because it is coordination and UI
/// state. The expensive work — audio, the analyzer, the language model, the
/// pasteboard dance — lives behind `SpeechEngine`, `TranscriptCleaner` and
/// `TextInjector` and is awaited, never blocked on.
@MainActor
@Observable
final class DictationController {

    // MARK: - Observable state

    private(set) var phase: DictationPhase = .idle
    private(set) var modelState: ModelState = .unknown
    /// Live transcript shown in the HUD while speaking.
    private(set) var liveText: String = ""
    /// Microphone level, 0...1, sampled for the HUD's waveform.
    private(set) var inputLevel: Float = 0
    private(set) var lastError: String?
    /// Locales this Mac can transcribe. Loaded once at launch; the Settings
    /// language picker reads it.
    private(set) var supportedLocales: [Locale] = []

    let settings: AppSettings
    let permissions: PermissionsModel
    let history = TranscriptHistory()

    // MARK: - Collaborators

    private let engine = SpeechEngine()
    private let cleaner = TranscriptCleaner()
    private let hud = HUDController()

    private var monitor: HotkeyMonitor?
    private var target: FocusSnapshot?

    private var autoStopTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var recordingStartedAt: ContinuousClock.Instant?

    init(settings: AppSettings, permissions: PermissionsModel) {
        self.settings = settings
        self.permissions = permissions
    }

    // MARK: - Lifecycle

    func start() {
        permissions.refresh()

        // Logged individually because "the tap failed" does not say which of the
        // two permissions is missing, and they live in different Settings panes.
        Log.app.info(
            """
            Permissions — microphone: \(String(describing: self.permissions.microphone), privacy: .public),             accessibility: \(self.permissions.accessibility, privacy: .public),             inputMonitoring: \(self.permissions.inputMonitoring, privacy: .public)
            """
        )

        installHotkeyMonitor()
        observeSettings()
        hud.attach(controller: self)

        Task {
            supportedLocales = await ModelCatalog.supportedLocales()
            await refreshModelAndPrewarm()
        }
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        autoStopTask?.cancel()
        levelTask?.cancel()
        dismissTask?.cancel()
    }

    private func installHotkeyMonitor() {
        let monitor = HotkeyMonitor { [weak self] event in
            // Called on the tap thread; hop to the main actor to touch state.
            Task { @MainActor in self?.handle(event) }
        }
        monitor.setTrigger(settings.triggerKey)

        do {
            try monitor.start()
            self.monitor = monitor
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.input.error("Hotkey monitor failed: \(error.localizedDescription)")

            // Actively request the permissions rather than only reporting them.
            //
            // This is not just a convenience: an app that has never *asked* for
            // Accessibility or Input Monitoring does not appear in the System
            // Settings lists at all, so the user has nothing to switch on and
            // no obvious way to fix things. Asking registers Murmur with TCC
            // and shows the system prompt.
            permissions.refresh()
            if !permissions.accessibility { permissions.requestAccessibility() }
            if !permissions.inputMonitoring { permissions.requestInputMonitoring() }
        }
    }

    /// Retries after the user grants permissions.
    func retryHotkeyMonitor() {
        guard monitor == nil else { return }
        permissions.refresh()
        installHotkeyMonitor()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.triggerKey
            _ = settings.localeIdentifier
            _ = settings.customVocabulary
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.monitor?.setTrigger(self.settings.triggerKey)

                // Re-arm first, synchronously. `refreshModelAndPrewarm` can
                // spend minutes downloading a model, and with no observation
                // registered any setting changed during that window would be
                // missed for good. `onChange` is one-shot, so re-registering
                // here cannot recurse.
                self.observeSettings()

                await self.refreshModelAndPrewarm()
            }
        }
    }

    // MARK: - Model

    func refreshModelAndPrewarm() async {
        let locale = settings.snapshot.locale
        modelState = await ModelCatalog.state(for: locale)

        if case .notInstalled = modelState {
            await downloadModel()
        }

        guard modelState.isReady else { return }

        await engine.configure(
            locale: locale,
            vocabulary: settings.snapshot.vocabularyTerms
        ) { [weak self] text in
            Task { @MainActor in self?.liveText = text }
        }

        do {
            try await engine.prewarm()
        } catch {
            Log.speech.error("Prewarm failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func downloadModel() async {
        let locale = settings.snapshot.locale
        modelState = .downloading(0)
        do {
            try await ModelCatalog.install(locale: locale) { [weak self] fraction in
                Task { @MainActor in self?.modelState = .downloading(fraction) }
            }
            modelState = .installed
        } catch {
            modelState = .failed(error.localizedDescription)
            Log.speech.error("Model install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hotkey handling

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .triggerDown:
            switch settings.activationMode {
            case .pushToTalk:
                begin()
            case .toggle:
                phase.isRecording ? finish() : begin()
            }

        case .triggerUp:
            // Ignored entirely in toggle mode: the release of a tap must not
            // immediately stop the dictation it just started.
            if settings.activationMode == .pushToTalk, phase.isRecording { finish() }

        case .cancel:
            cancel(reason: "Cancelled")
        }
    }

    // MARK: - Dictation

    func begin() {
        // A finished dictation lingers for ~1.4 s so the HUD can show its
        // outcome. Without this, every press inside that window would be
        // silently dropped — and speaking twice in quick succession is the
        // normal way this app gets used.
        if case .finished = phase {
            dismissTask?.cancel()
            phase = .idle
            liveText = ""
            hud.dismiss()
        }

        guard phase == .idle else { return }

        guard modelState.isReady else {
            flash(.discarded(reason: "Speech model not ready"))
            return
        }
        guard permissions.microphone != .denied else {
            flash(.discarded(reason: "Microphone access denied"))
            return
        }

        // Order matters: capture the target *before* anything of ours can
        // appear on screen, so we record where the user actually was.
        target = FocusSnapshot.captureFrontmost()

        liveText = ""
        phase = .listening
        recordingStartedAt = .now
        monitor?.setCapturing(true)

        dismissTask?.cancel()
        if settings.showHUD { hud.show() }
        playSound(named: "Tink")

        startLevelPolling()
        scheduleAutoStop()

        Task {
            do {
                try await engine.beginCapture()
            } catch {
                Log.audio.error("Capture failed: \(error.localizedDescription)")
                await abort(reason: error.localizedDescription)
            }
        }
    }

    func finish() {
        guard phase == .listening else { return }

        // A press too short to contain speech is almost always a stray brush of
        // the key; treat it as if it never happened rather than pasting noise.
        if let started = recordingStartedAt {
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(settings.minimumDictationMilliseconds) {
                cancel(reason: nil)
                return
            }
        }

        phase = .finalizing
        monitor?.setCapturing(false)
        autoStopTask?.cancel()
        stopLevelPolling()
        playSound(named: "Pop")

        Task { await completeDictation() }
    }

    private func completeDictation() async {
        let snapshot = settings.snapshot

        let raw: String
        do {
            raw = try await engine.endCapture()
        } catch {
            await abort(reason: error.localizedDescription)
            return
        }

        guard !raw.isEmpty else {
            flash(.discarded(reason: "Nothing was said"))
            await rearm()
            return
        }

        // Cleanup is optional and always falls back to `raw`.
        var text = raw
        if snapshot.stripFillers || snapshot.polishWithAppleIntelligence {
            phase = .polishing
            let result = await cleaner.clean(raw, settings: snapshot)
            text = result.text
            if case .keptRaw(_, let reason?) = result {
                Log.cleanup.info("Kept raw transcript: \(reason, privacy: .public)")
            }
        }

        // Cleanup must never be able to turn real speech into nothing.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.cleanup.warning("Cleanup emptied the transcript; using the raw text")
            text = raw
        }

        phase = .delivering
        let delivery = await TextInjector.deliver(text, to: target, settings: snapshot)

        history.add(text, destination: target?.displayName, limit: snapshot.historyLimit)

        switch delivery {
        case .pasted:
            flash(.pasted)
        case .leftOnClipboard(let reason):
            flash(.copied(reason: reason))
        case .failed(let reason):
            // Deliberately distinct from `.copied`: the text is NOT on the
            // clipboard, and telling the user it is would be a lie they act on.
            Log.output.error("Delivery failed: \(reason, privacy: .public)")
            flash(.discarded(reason: reason))
        }

        await rearm()
    }

    func cancel(reason: String?) {
        guard phase.isActive else { return }

        autoStopTask?.cancel()
        stopLevelPolling()
        monitor?.setCapturing(false)

        Task {
            await engine.cancelCapture()
            await rearm()
        }

        if let reason {
            flash(.discarded(reason: reason))
        } else {
            phase = .idle
            hud.dismiss()
        }
    }

    private func abort(reason: String) async {
        // Without these the level loop spins at 30 Hz forever and the HUD
        // waveform freezes mid-height.
        autoStopTask?.cancel()
        stopLevelPolling()
        monitor?.setCapturing(false)

        await engine.cancelCapture()
        lastError = reason
        flash(.discarded(reason: reason))
        await rearm()
    }

    /// Returns to idle and prepares the next session so the following key-down
    /// is as fast as this one was.
    private func rearm() async {
        monitor?.setCapturing(false)
        target = nil
        recordingStartedAt = nil
        do {
            try await engine.prewarm()
        } catch {
            Log.speech.error("Re-prewarm failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HUD helpers

    /// Shows a terminal state briefly, then returns to idle.
    private func flash(_ outcome: DictationOutcome) {
        phase = .finished(outcome)

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, let self else { return }
            if case .finished = self.phase {
                self.phase = .idle
                self.liveText = ""
                self.hud.dismiss()
            }
        }
    }

    private func startLevelPolling() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // `inputLevel` is nonisolated, so this never contends with the
                // engine actor for the sake of an animation.
                self.inputLevel = self.engine.inputLevel
                try? await Task.sleep(for: .milliseconds(33))   // ~30 fps
            }
        }
    }

    private func stopLevelPolling() {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        let limit = settings.maxDictationSeconds
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.phase.isRecording else { return }
            Log.audio.info("Auto-stopping at the \(limit, privacy: .public)s limit")
            // Stop and *process* what was captured rather than discarding it.
            self.finish()
        }
    }

    private func playSound(named name: String) {
        guard settings.playSounds else { return }
        NSSound(named: name)?.play()
    }
}
