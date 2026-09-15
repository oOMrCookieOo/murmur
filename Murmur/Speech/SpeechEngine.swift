import AVFoundation
import Foundation
import Speech

/// Drives `SpeechAnalyzer` + `SpeechTranscriber` from live microphone audio.
///
/// ## Why this is fast
///
/// The expensive parts of a dictation are loading the speech model and building
/// the analyzer graph. Doing either at key-down would blow the latency budget
/// on its own, so neither happens there:
///
/// 1. `SpeechAnalyzer.Options.modelRetention = .processLifetime` keeps the model
///    resident in memory between dictations instead of unloading it each time.
/// 2. `prepareToAnalyze(in:)` builds the graph ahead of time.
/// 3. A complete session is prepared during idle time — at launch, and again
///    immediately after each dictation finishes — so key-down only has to call
///    `start(inputSequence:)` and open the mic.
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
            case .microphonePermissionDenied:
                return "Microphone access was denied."
            case .noInputDevice:
                return "No microphone is available."
            case .noCompatibleAudioFormat:
                return "No audio format compatible with the speech model."
            case .modelUnavailable(let id):
                return "The speech model for \(id) is not installed."
            }
        }
    }

    /// Everything needed for one dictation, built ahead of time.
    private struct PreparedSession {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let analyzerFormat: AVAudioFormat
        let stream: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Error>
    }

    /// Converts and forwards render-thread buffers.
    ///
    /// `@unchecked Sendable` is accurate here: every member is touched only from
    /// the audio render thread, which AVAudioEngine guarantees is serial. The
    /// meter and the stream continuation are themselves thread-safe.
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
            // Never log or throw from here: this is the render thread.
            // Dropping one buffer degrades a word; blocking glitches the audio.
            guard let converted = try? converter.convertBuffer(buffer, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private let audioEngine = AVAudioEngine()
    private let meter = LevelMeter()

    private var prepared: PreparedSession?
    private var sink: TapSink?
    private var isCapturing = false
    private var locale: Locale = Locale(identifier: "en-US")
    private var volatileTextHandler: (@Sendable (String) -> Void)?

    /// Live input level, readable without awaiting the actor so the HUD can
    /// poll it from the main thread without contending for actor time.
    nonisolated var inputLevel: Float { meter.value }

    // MARK: - Configuration

    func configure(locale: Locale, onVolatileText: @escaping @Sendable (String) -> Void) {
        if self.locale != locale {
            self.locale = locale
            // Locale changed: the prepared session is for the wrong language.
            discardPreparedSession()
        }
        self.volatileTextHandler = onVolatileText
    }

    // MARK: - Prewarming

    /// Builds and warms a session so the next key-down is cheap. Safe to call
    /// repeatedly; does nothing if a session is already prepared.
    func prewarm() async throws {
        guard prepared == nil, !isCapturing else { return }

        guard let resolved = await ModelCatalog.resolve(locale) else {
            throw EngineError.modelUnavailable(locale.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            // `.volatileResults` drives the live HUD preview.
            // `.fastResults` trades a little accuracy for earlier finalisation,
            // which is exactly the trade dictation wants.
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

        // The expensive call. Done here, off the critical path.
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        prepared = PreparedSession(
            transcriber: transcriber,
            analyzer: analyzer,
            analyzerFormat: format,
            stream: stream,
            continuation: continuation,
            results: makeResultsTask(for: transcriber)
        )

        Log.speech.info("Prewarmed session for \(resolved.identifier(.bcp47), privacy: .public)")
    }

    /// Accumulates finalised text and streams partial text to the HUD.
    private func makeResultsTask(for transcriber: SpeechTranscriber) -> Task<String, Error> {
        let onVolatile = volatileTextHandler
        return Task<String, Error>.detached(priority: .userInitiated) {
            var finalized = AttributedString()

            for try await result in transcriber.results {
                if result.isFinal {
                    finalized.append(result.text)
                    onVolatile?(String(finalized.characters))
                } else {
                    // Volatile results replace, not append: show the settled
                    // text plus the current in-flight guess.
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
        guard !isCapturing else { return }

        guard await Self.ensureMicrophoneAccess() else {
            throw EngineError.microphonePermissionDenied
        }

        // Normally a no-op; covers the case where prewarming failed earlier.
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

        // 2048 frames is ~43 ms at 48 kHz. The header documents a supported
        // range of 100-400 ms and the system may clamp upward; asking for less
        // costs nothing and wins latency wherever it is honoured.
        //
        // `installAudioTap` is the macOS 27 replacement for `installTap`. It
        // hands over an `AVReadOnlyAudioPCMBuffer`, which is a Sendable value
        // type rather than a recycled reference, so copying it here gives us a
        // buffer we genuinely own for the rest of the pipeline.
        try input.installAudioTap(onBus: 0, bufferSize: 2048, format: inputFormat) { readOnlyBuffer, _ in
            newSink.receive(AVAudioPCMBuffer(copying: readOnlyBuffer))
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true

        Log.audio.info("Capture started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    /// Stops the mic, drains the analyzer and returns the final transcript.
    func endCapture() async throws -> String {
        guard isCapturing, let session = prepared else { return "" }

        teardownAudio()
        session.continuation.finish()

        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await session.results.value

        prepared = nil
        isCapturing = false
        meter.reset()

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandons the dictation without producing text.
    func cancelCapture() async {
        guard isCapturing, let session = prepared else { return }

        teardownAudio()
        session.continuation.finish()
        await session.analyzer.cancelAndFinishNow()
        session.results.cancel()

        prepared = nil
        isCapturing = false
        meter.reset()

        Log.audio.info("Capture cancelled")
    }

    private func teardownAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        sink = nil
    }

    private func discardPreparedSession() {
        guard let session = prepared, !isCapturing else { return }
        session.continuation.finish()
        session.results.cancel()
        prepared = nil
    }

    // MARK: - Permissions

    /// macOS has no `AVAudioSession`; microphone consent goes through
    /// `AVCaptureDevice` instead.
    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
