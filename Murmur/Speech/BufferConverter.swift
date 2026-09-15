import AVFoundation

/// Reformats microphone buffers into the format `SpeechAnalyzer` asked for.
///
/// The hardware gives us whatever the current input device runs at (48 kHz
/// stereo on most Macs, 16 kHz mono on some headsets); the analyzer wants its
/// own specific format. One converter instance is reused across buffers so the
/// resampler keeps its internal state and there are no clicks at buffer seams.
///
/// Not thread-safe by design: it is only ever touched from the audio render
/// thread, which is serial.
final class BufferConverter {

    enum ConversionError: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format

        // Already in the right format: pass it straight through.
        //
        // Safe because the caller owns `buffer` outright — it is copied out of
        // the tap's `AVReadOnlyAudioPCMBuffer` before it reaches us, so unlike
        // the old `installTap` there is no recycled engine buffer to outlive.
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // No priming latency. We are converting a live stream where a few
            // samples of extra filter accuracy are worth far less than the
            // delay priming would add to every single buffer.
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ConversionError.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            // Feed the single input buffer once, then report starvation so the
            // converter emits what it has instead of blocking for more.
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else { throw ConversionError.conversionFailed(nsError) }
        return conversionBuffer
    }
}
