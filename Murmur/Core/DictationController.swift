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
    /// Microphone level, 0...1, sampled for the HUD's waveform.
    private(set) var inputLevel: Float = 0
    private(set) var lastError: String?

    /// Key-up → paste, for the most recent dictation.
    private(set) var lastLatencyMilliseconds: Int?
    /// Median of the recent window, which is the number actually worth judging.
    private(set) var medianLatencyMilliseconds: Int?
    private var recentLatencies: [Int] = []
    /// Locales this Mac can transcribe. Loaded once at launch; the Settings
    /// language picker reads it.
    private(set) var supportedLocales: [Locale] = []
    /// Microphones currently attached, for the Settings picker.
    private(set) var inputDevices: [AudioInputDevice] = []
    /// Installed application names, fed to the recogniser as vocabulary.
    private(set) var appNames: [String] = []

    let settings: AppSettings
    let permissions: PermissionsModel
    let history: TranscriptHistory

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
    /// Set the instant the trigger is released; the origin for latency.
    private var keyUpAt: ContinuousClock.Instant?

    init(settings: AppSettings, permissions: PermissionsModel) {
        self.settings = settings
        self.permissions = permissions
        self.history = TranscriptHistory(limit: settings.historyLimit)
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

        inputDevices = AudioDevices.inputs()
        appNames = AppIndex.installedNames()

        Task {
            supportedLocales = await ModelCatalog.supportedLocales()
            await refreshModelAndPrewarm()
        }
    }

    /// The user's own terms, plus installed app names when enabled.
    ///
    /// App names go last so a term the user typed themselves wins if both
    /// somehow matter, and duplicates are removed because the same name can
    /// appear in both lists.
    private func vocabulary(for snapshot: SettingsData) -> [String] {
        var terms = snapshot.vocabularyTerms
        if snapshot.includeAppNamesInVocabulary {
            let existing = Set(terms.map { $0.lowercased() })
            terms += appNames.filter { !existing.contains($0.lowercased()) }
        }
        return terms
    }

    /// Re-reads attached microphones. Cheap, and devices come and go.
    func refreshInputDevices() {
        inputDevices = AudioDevices.inputs()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        autoStopTask?.cancel()
        levelTask?.cancel()
        dismissTask?.cancel()
        hud.dismiss()

        // Best effort on the way out: `applicationWillTerminate` is synchronous
        // and will not wait for this, but releasing the microphone promptly
        // stops the orange recording indicator lingering after the app is gone.
        // Process exit is the real backstop.
        Task { await engine.cancelCapture() }
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
            _ = settings.includeAppNamesInVocabulary
            _ = settings.inputDeviceUID
            _ = settings.autoStopOnSilence
            _ = settings.activationMode
            _ = settings.historyLimit
            _ = settings.polishWithAppleIntelligence
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.monitor?.setTrigger(self.settings.triggerKey)
                self.history.applyLimit(self.settings.historyLimit)

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
        // One snapshot for the whole function: it spans several awaits, and
        // reading settings live either side of them can mix pre- and
        // post-change values into the same configuration.
        let snapshot = settings.snapshot
        let locale = snapshot.locale
        modelState = await ModelCatalog.state(for: locale)

        if case .notInstalled = modelState {
            await downloadModel()
        }

        guard modelState.isReady else { return }

        // Pin the model we depend on, and let go of anything a previous launch
        // reserved; there are only five slots system-wide.
        await ModelCatalog.releaseStaleReservations(keeping: locale)
        await ModelCatalog.ensureReserved(locale)

        await engine.configure(
            locale: locale,
            vocabulary: vocabulary(for: snapshot),
            inputDeviceUID: snapshot.inputDeviceUID,
            detectSpeechActivity: snapshot.autoStopOnSilence
                && snapshot.activationMode == .toggle
        )

        do {
            try await engine.prewarm()
        } catch {
            Log.speech.error("Prewarm failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }

        // Only when the user has opted in. Warming the foundation model costs
        // real memory, and loading it for a feature that is switched off would
        // be exactly the bloat this app is trying to avoid.
        if snapshot.polishWithAppleIntelligence {
            await cleaner.prewarm()
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
            hud.dismiss()
        }

        guard phase == .idle else {
            // Not silent: the processing tail can be seconds long with cleanup
            // enabled, and a dropped press with no feedback feels identical to
            // a broken app.
            Log.app.info("Press ignored while \(String(describing: self.phase), privacy: .public)")
            return
        }

        // Shown before the guards below, not after: `flash` only sets state,
        // and with no panel on screen a refused press produced no HUD, no
        // sound and no log — indistinguishable from the app being dead.
        if settings.showHUD { hud.show(position: settings.hudPosition) }

        guard modelState.isReady else {
            Log.app.info("Press refused: speech model not ready")
            flash(.discarded(reason: "Speech model not ready"))
            return
        }
        guard permissions.microphone != .denied else {
            Log.app.info("Press refused: microphone denied")
            flash(.discarded(reason: "Microphone access denied"))
            return
        }

        // Order matters: capture the target *before* anything of ours can
        // appear on screen, so we record where the user actually was.
        target = FocusSnapshot.captureFrontmost()

        phase = .listening
        recordingStartedAt = .now
        monitor?.setCapturing(true)

        dismissTask?.cancel()
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
                Log.app.info("Press too short; ignored")
                cancel(reason: nil)
                return
            }
        }

        keyUpAt = .now
        phase = .finalizing
        monitor?.setCapturing(false)
        autoStopTask?.cancel()
        stopLevelPolling()
        playSound(named: "Pop")

        Task { await completeDictation() }
    }

    private func completeDictation() async {
        let snapshot = settings.snapshot

        let startedAt = keyUpAt ?? .now
        let raw: String
        do {
            raw = try await engine.endCapture(
                tailGraceMilliseconds: snapshot.tailGraceMilliseconds,
                keyUpAt: startedAt
            )
        } catch {
            await abort(reason: error.localizedDescription)
            return
        }

        guard !raw.isEmpty else {
            Log.app.info("Dictation produced no text")
            flash(.discarded(reason: "Nothing was said"))
            await rearm()
            return
        }

        let transcribedAt = ContinuousClock.now

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

        let cleanedAt = ContinuousClock.now

        phase = .delivering
        let report = await TextInjector.deliver(text, to: target, settings: snapshot)

        history.add(text, destination: target?.displayName, limit: snapshot.historyLimit)
        recordLatency(from: startedAt, transcribedAt: transcribedAt, cleanedAt: cleanedAt, report: report)

        switch report.delivery {
        case .pasted(let confirmed):
            if !confirmed {
                Log.output.info("Paste posted but the read was never observed")
            }
            flash(.pasted(confirmed: confirmed))
        case .leftOnClipboard(let reason):
            // Logged because this is the outcome worth diagnosing: the words
            // are safe, but they did not go where the user was looking, and
            // without a reason in the log there is no way to find out why.
            Log.output.info("Left on clipboard: \(reason ?? "clipboard-only mode", privacy: .public)")
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

    // MARK: - Latency

    /// Records key-up → paste, broken down by stage.
    ///
    /// Measured to `report.pastedAt` rather than to the return of `deliver`:
    /// delivery does not return until the clipboard has been restored ~250 ms
    /// later, but the text is on screen the moment Cmd+V goes out. Timing the
    /// return would overstate what the user actually experiences.
    private func recordLatency(
        from start: ContinuousClock.Instant,
        transcribedAt: ContinuousClock.Instant,
        cleanedAt: ContinuousClock.Instant,
        report: TextInjector.DeliveryReport
    ) {
        guard let pastedAt = report.pastedAt else {
            // Clipboard-only and failed deliveries have no paste to measure.
            // Clearing avoids the menu showing a stale figure from an earlier
            // dictation as though it described this one.
            lastLatencyMilliseconds = nil
            return
        }

        func milliseconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1000)
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }

        let transcribe = milliseconds(transcribedAt - start)
        let cleanup = milliseconds(cleanedAt - transcribedAt)
        let deliver = milliseconds(pastedAt - cleanedAt)
        let total = milliseconds(pastedAt - start)

        lastLatencyMilliseconds = total
        recentLatencies.append(total)
        if recentLatencies.count > 50 { recentLatencies.removeFirst() }

        let sorted = recentLatencies.sorted()
        // True median: the midpoint of the two central samples on an even
        // window, rather than the upper one.
        medianLatencyMilliseconds = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]

        Log.app.info(
            """
            Latency \(total, privacy: .public)ms             (transcribe \(transcribe, privacy: .public)ms,             cleanup \(cleanup, privacy: .public)ms,             deliver \(deliver, privacy: .public)ms)             median \(self.medianLatencyMilliseconds ?? 0, privacy: .public)ms             over \(self.recentLatencies.count, privacy: .public)
            """
        )
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
                self.checkForSilence()
                self.checkForInterruption()
                try? await Task.sleep(for: .milliseconds(33))   // ~30 fps
            }
        }
    }

    /// Ends the dictation once the speaker has clearly finished.
    ///
    /// Toggle mode only. In hold mode the key already says when to stop, and
    /// cutting someone off mid-pause while they are still holding it would be
    /// both surprising and unfixable.
    private func checkForSilence() {
        guard settings.autoStopOnSilence,
              settings.activationMode == .toggle,
              phase.isRecording,
              let quiet = engine.silenceDuration,
              quiet > .milliseconds(settings.silenceTimeoutMilliseconds)
        else { return }

        Log.audio.info("Stopping after silence")
        finish()
    }

    /// Ends the dictation when the audio route changed underneath it.
    ///
    /// The engine cannot finish on its own — only the controller knows what to
    /// do with the transcript — so it raises a flag and we salvage here.
    private func checkForInterruption() {
        guard phase.isRecording, engine.captureWasInterrupted else { return }
        Log.audio.info("Ending dictation after an audio route change")
        finish()
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
