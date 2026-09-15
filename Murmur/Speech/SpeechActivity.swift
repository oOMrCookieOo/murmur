import Foundation
import os

/// Tracks when speech was last heard, so a dictation can stop itself once the
/// speaker has clearly finished.
///
/// Fed from the microphone level computed for the HUD, and read without
/// touching the engine actor — the same approach as `LevelMeter`.
///
/// `SpeechDetector` was tried first and produced no results at all against real
/// speech, so auto-stop could never have fired. The level is a cruder signal but
/// it demonstrably works, costs nothing extra, and keeps the analyzer to a
/// single module.
final class SpeechActivity: Sendable {

    /// Normalised level above which a buffer counts as speech rather than room
    /// tone. The scale is dB-mapped, so this sits comfortably above the noise
    /// floor of a quiet room without needing the speaker to project.
    static let speechThreshold: Float = 0.22

    private struct State {
        var lastSpeechAt: ContinuousClock.Instant?
        var hasHeardSpeech = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func noteSpeech() {
        state.withLock {
            $0.lastSpeechAt = .now
            $0.hasHeardSpeech = true
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    /// How long it has been quiet, or nil if the speaker has not started yet.
    ///
    /// Deliberately nil before the first word: otherwise every dictation would
    /// auto-stop during the pause between pressing the key and starting to
    /// speak, which is the one moment silence is expected.
    var silenceDuration: Duration? {
        state.withLock { current in
            guard current.hasHeardSpeech, let last = current.lastSpeechAt else { return nil }
            return ContinuousClock.now - last
        }
    }
}
