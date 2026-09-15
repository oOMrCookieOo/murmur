import SwiftUI

/// The floating pill: a state glyph, a live waveform, and the transcript so far.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if controller.phase.isRecording {
                    Waveform(level: controller.inputLevel)
                        .frame(height: 14)
                } else if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: controller.phase)
    }

    @ViewBuilder
    private var glyph: some View {
        switch controller.phase {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        case .finalizing, .polishing, .delivering:
            ProgressView().controlSize(.small)
        case .finished(.pasted):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        case .finished(.copied):
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 15))
        case .finished(.discarded):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }

    private var title: String {
        switch controller.phase {
        case .idle:                    return "Ready"
        case .listening:               return "Listening — Esc to cancel"
        case .finalizing:              return "Transcribing"
        case .polishing:               return "Cleaning up"
        case .delivering:              return "Pasting"
        case .finished(.pasted):       return "Pasted"
        case .finished(.copied(nil)):  return "Copied to clipboard"
        case .finished(.copied(let reason?)):
            return "Copied to clipboard — \(reason)"
        case .finished(.discarded(let reason)):
            return reason
        }
    }

    private var subtitle: String {
        controller.liveText
    }
}

/// Simple level-driven bar meter.
///
/// Bars are offset from the centre so the shape reads as a voice, and each one
/// is scaled by a fixed fraction of the current level so the motion looks
/// organic without needing a real FFT.
private struct Waveform: View {
    let level: Float

    private static let weights: [Float] = [0.35, 0.65, 1.0, 0.8, 0.5, 0.9, 0.6, 0.3]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3, height: height(for: weight))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for weight: Float) -> CGFloat {
        let minimum: Float = 3
        let maximum: Float = 14
        return CGFloat(minimum + (maximum - minimum) * min(level * weight * 1.6, 1))
    }
}
