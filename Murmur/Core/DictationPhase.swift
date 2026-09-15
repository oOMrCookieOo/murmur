import Foundation

/// Where a dictation ended up. Drives the closing HUD message.
enum DictationOutcome: Equatable, Sendable {
    /// Text was pasted into the target app. `confirmed` is false when the
    /// keystroke went out but the target was never observed taking the text.
    case pasted(confirmed: Bool)
    /// Text was left on the clipboard (clipboard-only mode, or no safe target).
    case copied(reason: String?)
    /// Nothing usable was produced, or the user cancelled.
    case discarded(reason: String)
}

/// The dictation state machine.
///
/// Transitions are strictly forward except `cancel`, which can fire from any
/// active phase and always lands on `.idle`.
///
///     idle → listening → finalizing → polishing? → delivering → finished → idle
enum DictationPhase: Equatable, Sendable {
    /// Nothing happening. The engine may be prewarming in the background.
    case idle
    /// Mic is open, audio is flowing into the analyzer.
    case listening
    /// Key released; draining the analyzer for the final transcript.
    case finalizing
    /// Running the optional on-device cleanup pass.
    case polishing
    /// Writing to the pasteboard / posting the paste keystroke.
    case delivering
    /// Terminal state shown briefly in the HUD before returning to `.idle`.
    case finished(DictationOutcome)

    /// True while the user is actively dictating or we are still working on it.
    var isActive: Bool {
        switch self {
        case .idle, .finished: return false
        case .listening, .finalizing, .polishing, .delivering: return true
        }
    }

    /// True only while the microphone is actually open.
    var isRecording: Bool { self == .listening }
}
