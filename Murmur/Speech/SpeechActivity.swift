import Foundation
import os

/// Tracks when speech was last heard, so a dictation can stop itself once the
/// speaker has clearly finished.
///
/// Fed by `SpeechDetector` — Apple's on-device voice activity detection — and
/// read without touching the engine actor, the same approach as `LevelMeter`.
final class SpeechActivity: Sendable {
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
