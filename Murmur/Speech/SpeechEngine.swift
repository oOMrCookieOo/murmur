import AVFoundation
import Foundation
import Speech
import os

/// Drives `SpeechAnalyzer` + `SpeechTranscriber` from live microphone audio.
///
/// ## Why this is fast
///
/// The expensive parts of a dictation are loading the speech model and building
/// the analyzer graph. Measured on Apple Silicon: `bestAvailableAudioFormat`
/// ~58 ms and `prepareToAnalyze(in:)` ~35 ms on first use, falling to ~1.5 ms
/// once the model is resident. `start(inputSequence:)` is ~9 µs. So none of the
/// cost is where it looks like it is, and the design follows from that:
///
/// 1. `modelRetention: .processLifetime` keeps the model resident between
///    dictations instead of unloading it each time.
/// 2. `prepareToAnalyze(in:)` builds the graph ahead of time.
/// 3. A complete session is prepared during idle — at launch, and again the
///    moment each dictation finishes — so key-down only opens the mic.
///
/// A `SpeechAnalyzer` cannot be restarted once finished, which is why each
/// dictation gets a fresh prepared session rather than reusing one.
actor SpeechEngine {

    enum EngineError: LocalizedError {
        case microphonePermissionDenied
        case noInputDevice
        case noCompatibleAudioFormat
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied: return "Microphone access was denied."
            case .noInputDevice:              return "No microphone is available."
            case .noCompatibleAudioFormat:    return "No audio format compatible with the speech model."
            case .modelUnavailable(let id):   return "The speech model for \(id) is not installed."
            }
        }
    }

    /// Explicit states, because a simple `isCapturing` flag set at the *end* of
    /// an async function is a re-entrancy hole: the actor suspends at every
    /// `await`, so a second caller can walk straight past the guard while the
    /// first is still starting up.
    private enum CaptureState {
        case idle
        /// Between entering `beginCapture` and the engine actually running.
        case starting
        case capturing
        /// Draining the analyzer in `endCapture`.
        case finishing
    }

    /// Holds the transcript finalised so far, readable from outside the results
    /// task so a finalisation timeout can still salvage what was recognised.
    private final class TranscriptBox: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: "")
        var text: String { state.withLock { $0 } }
        func set(_ value: String) { state.withLock { $0 = value } }
    }

    /// Everything needed for one dictation, built ahead of time.
    private struct PreparedSession {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let analyzerFormat: AVAudioFormat
        let stream: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Error>
        let transcript: TranscriptBox
    }

    /// Converts and forwards render-thread buffers.
    ///
    /// `@unchecked Sendable` is accurate: every member is touched only from the
    /// audio render thread, which AVAudioEngine guarantees is serial. The meter
    /// and the stream continuation are themselves thread-safe.
    private final class TapSink: @unchecked Sendable {
        private let converter = BufferConverter()
        private let analyzerFormat: AVAudioFormat
        private let continuation: AsyncStream<AnalyzerInput>.Continuation
        private let meter: LevelMeter

        init(analyzerFormat: AVAudioFormat,
             continuation: AsyncStream<AnalyzerInput>.Continuation,
             meter: LevelMeter) {
            self.analyzerFormat = analyzerFormat
            self.continuation = continuation
            self.meter = meter
        }

        func receive(_ buffer: AVAudioPCMBuffer) {
            meter.update(LevelMeter.normalisedLevel(of: buffer))
            // No unbounded work here: this is the render thread. Dropping one
            // buffer degrades a word; blocking glitches the audio.
            guard let converted = try? converter.convertBuffer(buffer, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private let audioEngine = AVAudioEngine()
    private let meter = LevelMeter()

    private var prepared: PreparedSession?
    private var sink: TapSink?
    private var captureState: CaptureState = .idle
    private var locale: Locale = Locale(identifier: "en-US")
    private var vocabulary: [String] = []
    private var volatileTextHandler: (@Sendable (String) -> Void)?

    /// In-flight prewarm, so concurrent callers join it instead of each building
    /// a session and silently orphaning the loser's analyzer and results task.
    private var prewarmTask: Task<Void, Error>?

    private var configurationObserver: (any NSObjectProtocol)?

    /// Live input level, readable without awaiting the actor so the HUD can poll
    /// it from the main thread without contending for actor time.
    nonisolated var inputLevel: Float { meter.value }

    // MARK: - Configuration

    func configure(
        locale: Locale,
        vocabulary: [String],
        onVolatileText: @escaping @Sendable (String) -> Void
    ) async {
        self.volatileTextHandler = onVolatileText

        // Both are baked into the prepared session, so either changing means
        // the prepared one is stale.
        if self.locale != locale || self.vocabulary != vocabulary {
            self.locale = locale
            self.vocabulary = vocabulary
            await discardPreparedSession()
        }
        startObservingConfigurationChanges()
    }

    /// An input-device change (AirPods connecting, a dock being unplugged) stops
    /// `AVAudioEngine` and silently kills the tap. Without this the dictation
    /// would just produce nothing, with no error anywhere.
    private func startObservingConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        guard captureState == .capturing else { return }
        Log.audio.warning("Audio configuration changed mid-dictation; capture may be truncated")
    }

    // MARK: - Prewarming

    /// Builds and warms a session so the next key-down is cheap.
    /// Safe to call concurrently; callers share one in-flight attempt.
    func prewarm() async throws {
        if let existing = prewarmTask {
            return try await existing.value
        }
        guard prepared == nil, captureState == .idle else { return }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performPrewarm()
        }
        prewarmTask = task

        do {
            try await task.value
            prewarmTask = nil
        } catch {
            prewarmTask = nil
            throw error
        }
    }

    private func performPrewarm() async throws {
        guard prepared == nil else { return }

        guard let resolved = await ModelCatalog.resolve(locale) else {
            throw EngineError.modelUnavailable(locale.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            // `.volatileResults` drives the live HUD preview. `.fastResults`
            // trades a little accuracy for earlier finalisation, which is
            // exactly the trade dictation wants.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noCompatibleAudioFormat
        }

        // Bias recognition toward the user's own words — names, jargon, project
        // nouns. This is the on-device equivalent of a custom dictionary, and
        // it is the single biggest accuracy lever available to us: the model is
        // fixed, but what it expects to hear is not.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
            Log.speech.info("Applied \(self.vocabulary.count, privacy: .public) vocabulary terms")
        }

        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let transcript = TranscriptBox()

        prepared = PreparedSession(
            transcriber: transcriber,
            analyzer: analyzer,
            analyzerFormat: format,
            stream: stream,
            continuation: continuation,
            results: makeResultsTask(for: transcriber, transcript: transcript),
            transcript: transcript
        )

        Log.speech.info("Prewarmed session for \(resolved.identifier(.bcp47), privacy: .public)")
    }

    /// Accumulates finalised text and streams partial text to the HUD.
    ///
    /// `SpeechTranscriber.Result.text` carries its own leading space, so plain
    /// appending produces correct spacing between segments.
    private func makeResultsTask(
        for transcriber: SpeechTranscriber,
        transcript: TranscriptBox
    ) -> Task<String, Error> {
        let onVolatile = volatileTextHandler
        return Task<String, Error>.detached(priority: .userInitiated) {
            var finalized = AttributedString()

            for try await result in transcriber.results {
                if result.isFinal {
                    finalized.append(result.text)
                    let text = String(finalized.characters)
                    transcript.set(text)
                    onVolatile?(text)
                } else {
                    // Volatile results replace rather than append: they cover
                    // only the range after the finalised text.
                    var preview = finalized
                    preview.append(result.text)
                    onVolatile?(String(preview.characters))
                }
            }
            return String(finalized.characters)
        }
    }

    // MARK: - Capture

    func beginCapture() async throws {
        guard captureState == .idle else { return }
        // Claimed before the first await, which is what closes the re-entrancy
        // hole: the mic-permission dialog alone can suspend here for seconds.
        captureState = .starting

        do {
            guard await Self.ensureMicrophoneAccess() else {
                throw EngineError.microphonePermissionDenied
            }

            // Normally a no-op; covers a failed earlier prewarm.
            if prepared == nil { try await prewarm() }
            guard let session = prepared else { throw EngineError.noCompatibleAudioFormat }

            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw EngineError.noInputDevice
            }

            try await session.analyzer.start(inputSequence: session.stream)

            let newSink = TapSink(
                analyzerFormat: session.analyzerFormat,
                continuation: session.continuation,
                meter: meter
            )
            sink = newSink

            // `installAudioTap` is the macOS 27 replacement for `installTap`. It
            // hands over an `AVReadOnlyAudioPCMBuffer` — a Sendable value type
            // rather than a recycled reference — so copying it here yields a
            // buffer we genuinely own for the rest of the pipeline.
            //
            // The 2048-frame request (~43 ms) is advisory and measured to be
            // clamped up to 4800 frames (100 ms) on current hardware.
            try input.installAudioTap(onBus: 0, bufferSize: 2048, format: inputFormat) { readOnlyBuffer, _ in
                newSink.receive(AVAudioPCMBuffer(copying: readOnlyBuffer))
            }

            audioEngine.prepare()
            try audioEngine.start()
            captureState = .capturing

            Log.audio.info("Capture started at \(inputFormat.sampleRate, privacy: .public) Hz")
        } catch {
            // Without this, a throw after the tap is installed leaves it
            // installed forever: the next `installAudioTap` fails with -10863
            // and dictation is wedged until relaunch. An input-device change is
            // enough to trigger it.
            await resetAfterFailure()
            throw error
        }
    }

    /// Stops the mic, drains the analyzer and returns the final transcript.
    func endCapture() async throws -> String {
        guard captureState == .capturing, let session = prepared else { return "" }
        captureState = .finishing

        teardownAudio()
        session.continuation.finish()

        // Only Sendable pieces cross into the timeout closure.
        let analyzer = session.analyzer
        let results = session.results
        let transcript = session.transcript

        // Measured at 56-110 ms normally. Unbounded, it can hang the app dead:
        // the actor would be occupied, so even a cancel could not rescue it.
        let finalized = await withTimeout(.seconds(3)) { () -> String in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            return (try? await results.value) ?? transcript.text
        }

        let text: String
        if let finalized {
            text = finalized
        } else {
            // Salvage rather than lose the dictation entirely.
            Log.speech.error("Finalisation timed out; using the partial transcript")
            await analyzer.cancelAndFinishNow()
            results.cancel()
            text = transcript.text
        }

        prepared = nil
        captureState = .idle
        meter.reset()

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandons the dictation without producing text.
    func cancelCapture() async {
        guard captureState != .idle else { return }
        await resetAfterFailure()
        Log.audio.info("Capture cancelled")
    }

    /// Single recovery path, used by both cancellation and failure.
    /// Deliberately tolerant: it must work from any partially-started state.
    private func resetAfterFailure() async {
        teardownAudio()

        if let session = prepared {
            session.continuation.finish()
            await session.analyzer.cancelAndFinishNow()
            session.results.cancel()
            prepared = nil
        }

        captureState = .idle
        meter.reset()
    }

    private func teardownAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        sink = nil
    }

    private func discardPreparedSession() async {
        guard captureState == .idle, let session = prepared else { return }
        session.continuation.finish()
        await session.analyzer.cancelAndFinishNow()
        session.results.cancel()
        prepared = nil
    }

    // MARK: - Permissions

    /// macOS has no `AVAudioSession`; microphone consent goes through
    /// `AVCaptureDevice` instead.
    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default:    return false
        }
    }
}
