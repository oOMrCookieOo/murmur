import SwiftUI

/// The floating dictation indicator.
///
/// Liquid Glass, and while recording it is nothing but the level meter — no
/// glyph, no label, no transcript. The bars alone say "listening"; anything
/// else is furniture.
struct HUDView: View {
    @Bindable var controller: DictationController

    static let capsuleHeight: CGFloat = 48

    /// One width for every state.
    ///
    /// The capsule used to hug its content, so finishing a dictation shrank it
    /// from the meter's width down to the width of the word "Pasted" — a visible
    /// snap at exactly the moment you are looking at it. Holding the width
    /// constant makes the state change a cross-fade instead.
    static let capsuleWidth: CGFloat = 210

    /// Breathing room around the capsule inside the window.
    ///
    /// The window clips what it draws, and Liquid Glass renders a soft edge
    /// beyond the shape's bounds, so without this the glass would be sliced off
    /// square at the window edge.
    static let margin: CGFloat = 20

    /// Sized for the widest state, which is an outcome message rather than the
    /// meter. The capsule itself hugs its content, so it is smaller than this.
    static var windowSize: NSSize {
        NSSize(width: capsuleWidth + margin * 2, height: capsuleHeight + margin * 2)
    }

    var body: some View {
        content
            .padding(.horizontal, 20)
            .frame(height: Self.capsuleHeight)
            .fixedSize(horizontal: true, vertical: false)
            // `.clear`, not `.regular`: the reference look is barely there,
            // with the desktop clearly visible through it. A rounded rectangle
            // rather than a capsule — the radius is noticeably less than half
            // the height.
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            // A hairline rim, as in the reference. It also means the shape
            // stays legible against a background that happens to match the
            // glass, which `.clear` alone cannot guarantee.
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
            // Centres the capsule in the window. NSHostingView lays a root view
            // narrower than its frame out at the leading edge, which put the
            // pill left of centre on screen even though the window itself was
            // centred.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.18), value: controller.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .listening:
            Waveform(level: controller.inputLevel)
                .frame(width: Waveform.width, height: 24)
                .transition(.opacity)

        case .finalizing, .polishing, .delivering:
            // The meter would be lying here — the microphone is already closed.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.85)
                .tint(.white)
                .frame(width: 44)

        case .idle, .finished:
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                // White, not `.primary`. Over clear glass `.primary` resolves
                // to black in a light appearance, which reads as a mistake next
                // to the white bars.
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                // Shrinks a little before truncating, so a longer reason stays
                // readable inside the fixed width.
                .minimumScaleFactor(0.8)
                .transition(.opacity)
        }
    }

    /// Compact phrasings of the delivery reasons, for the fixed-width pill.
    /// The full wording stays in the log.
    private static func shortened(_ reason: String) -> String {
        switch reason {
        case "No editable field is focused": return "No text field"
        case "Focus moved to another app":   return "Focus moved"
        case "A password field is active":   return "Password field"
        case "Accessibility access not granted": return "Needs Accessibility"
        default: return "Copied — \(reason)"
        }
    }

    private var title: String {
        switch controller.phase {
        case .finished(.pasted(true)):  return "Pasted"
        // The keystroke went out but nothing was seen taking it, so claiming
        // success outright would be a guess.
        case .finished(.pasted(false)): return "Pasted — unverified"
        case .finished(.copied(nil)):   return "Copied"
        case .finished(.copied(let reason?)): return Self.shortened(reason)
        case .finished(.discarded(let reason)): return reason
        default: return "Ready"
        }
    }
}

/// Audio-trace level meter.
///
/// Many thin bars with irregular heights, which is what reads as a waveform.
/// An earlier version used few bars on a smooth cosine envelope and looked like
/// a bar chart being stretched — the irregularity is the whole effect.
///
/// Heights come from layered sines at unrelated frequencies rather than real
/// FFT bins: the microphone gives us one amplitude per buffer, so any per-bar
/// detail is decorative either way, and this costs nothing.
struct Waveform: View {
    let level: Float

    private static let barCount = 29
    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 2.5

    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    var body: some View {
        // 30 fps, and only ever on screen while recording.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.92))
                        .frame(width: Self.barWidth, height: height(index: index, phase: phase))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(index: Int, phase: TimeInterval) -> CGFloat {
        let minimum: CGFloat = 3
        let maximum: CGFloat = 24

        let i = Double(index)

        // Three unrelated frequencies so no repeating pattern is visible, and
        // the bars travel rather than pulsing in unison.
        let a = sin(i * 2.31 + phase * 6.1)
        let b = sin(i * 0.77 - phase * 3.9)
        let c = sin(i * 5.93 + phase * 9.3)
        let noise = (a + b * 0.65 + c * 0.45) / 2.1      // roughly -1...1
        let shaped = (noise + 1) / 2                      // 0...1

        // A gentle taper only — the reference is close to flat across the pill,
        // unlike a cosine envelope that pinches hard at the ends.
        let centre = Double(Self.barCount - 1) / 2
        let edge = 1 - pow(abs(i - centre) / centre, 3) * 0.35

        let amplitude = Double(min(level * 1.9, 1))
        let value = shaped * edge * (0.10 + 0.90 * amplitude)

        return minimum + (maximum - minimum) * CGFloat(min(max(value, 0), 1))
    }
}
