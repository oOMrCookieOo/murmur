import SwiftUI

/// The floating dictation pill.
///
/// Laid out as a fixed-width capsule with everything centred, so the indicator
/// keeps the same silhouette from "Listening" through to "Pasted" instead of
/// jumping around as its contents change. Text is the only thing that varies,
/// and it is length-limited so it cannot reflow the shape.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 20, height: 20)

            centrepiece

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.phase)
    }

    // MARK: - Leading glyph

    @ViewBuilder
    private var glyph: some View {
        switch controller.phase {
        case .listening:
            ZStack {
                Circle()
                    .fill(.red.opacity(0.18))
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }
        case .finalizing, .polishing, .delivering:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        case .finished(.pasted):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.green)
        case .finished(.copied):
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
        case .finished(.discarded):
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Centre

    @ViewBuilder
    private var centrepiece: some View {
        if controller.phase.isRecording {
            HStack(spacing: 10) {
                Waveform(level: controller.inputLevel)
                    .frame(width: 74, height: 18)

                Text(controller.liveText.isEmpty ? "Listening" : controller.liveText)
                    .font(.system(size: 12, weight: controller.liveText.isEmpty ? .medium : .regular))
                    .foregroundStyle(controller.liveText.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } else {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isError ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var isError: Bool {
        if case .finished(.discarded) = controller.phase { return true }
        return false
    }

    private var title: String {
        switch controller.phase {
        case .idle:                    return "Ready"
        case .listening:               return "Listening"
        case .finalizing:              return "Transcribing"
        case .polishing:               return "Cleaning up"
        case .delivering:              return "Pasting"
        case .finished(.pasted):       return "Pasted"
        case .finished(.copied(nil)):  return "Copied to clipboard"
        case .finished(.copied(let reason?)):
            return "Clipboard — \(reason)"
        case .finished(.discarded(let reason)):
            return reason
        }
    }
}

/// Symmetric level meter.
///
/// Bars are weighted outward from the centre so the shape reads as a voice
/// rather than a bar chart, and each is springed independently so the motion
/// stays fluid instead of stepping at the 30 Hz sample rate.
private struct Waveform: View {
    let level: Float

    private static let weights: [Float] = [0.30, 0.52, 0.76, 0.94, 1.0, 0.94, 0.76, 0.52, 0.30]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { index, weight in
                Capsule(style: .continuous)
                    .fill(.red.gradient)
                    .frame(width: 3, height: height(for: weight))
                    .animation(
                        .spring(response: 0.22, dampingFraction: 0.6)
                            .delay(Double(index) * 0.008),
                        value: level
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func height(for weight: Float) -> CGFloat {
        let floor: Float = 3
        let ceiling: Float = 18
        // Slight boost so ordinary speech reaches most of the range rather than
        // hovering near the bottom.
        let scaled = min(level * weight * 1.7, 1)
        return CGFloat(floor + (ceiling - floor) * scaled)
    }
}
