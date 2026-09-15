import Accelerate
import AVFoundation
import os

/// Thread-safe microphone level, written from the audio render thread and read
/// by the HUD.
///
/// Deliberately a poll-able value rather than a callback: invoking a closure
/// (and therefore possibly allocating a `Task`) from the render thread risks
/// blocking it, which shows up as audio glitches. The HUD reads this at 30 Hz.
final class LevelMeter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Float(0))

    var value: Float { state.withLock { $0 } }
    func update(_ newValue: Float) { state.withLock { $0 = newValue } }
    func reset() { update(0) }

    /// Normalised 0...1 loudness for `buffer`, on a dB scale so ordinary speech
    /// fills most of the range instead of hugging the bottom.
    static func normalisedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }

        // Loudest channel, not channel 0: on an interface whose mic is wired to
        // the right channel, metering only the left shows a flat line while
        // transcription works perfectly.
        var loudestMeanSquare: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var meanSquare: Float = 0
            vDSP_measqv(channels[channel], 1, &meanSquare, vDSP_Length(buffer.frameLength))
            loudestMeanSquare = max(loudestMeanSquare, meanSquare)
        }

        let rms = sqrt(loudestMeanSquare)
        let decibels = 20 * log10(max(rms, 1e-7))

        // -60 dB (near silence) → 0, 0 dB (clipping) → 1.
        return min(max((decibels + 60) / 60, 0), 1)
    }
}
