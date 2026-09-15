import Foundation
import Observation

/// How the trigger key behaves.
enum ActivationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Hold the key to record, release to transcribe. The default.
    case pushToTalk
    /// Tap once to start, tap again to stop. Useful for long dictations.
    case toggle

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pushToTalk: return "Hold to talk"
        case .toggle:     return "Tap to start / stop"
        }
    }
}

/// Whether to separate this dictation from whatever is already at the cursor.
enum SpacingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Paste exactly what was transcribed.
    case never
    /// Insert a leading space only when the cursor is not already after
    /// whitespace or at the start of a field.
    case smart
    /// Always insert a leading space.
    case always

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .never:  return "Never"
        case .smart:  return "Only when needed"
        case .always: return "Always"
        }
    }
}

/// What to do with the finished transcript.
enum DeliveryMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Paste into whatever app was frontmost when dictation began.
    case pasteAtCursor
    /// Never paste; just leave the text on the clipboard.
    case clipboardOnly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pasteAtCursor: return "Paste at cursor"
        case .clipboardOnly: return "Copy to clipboard only"
        }
    }
}

/// Plain value type holding every persisted preference.
///
/// Kept separate from `AppSettings` so the whole thing can be encoded in one shot
/// and compared for equality, which is what makes the autosave below cheap.
struct SettingsData: Codable, Equatable, Sendable {
    var triggerKey: TriggerKey = .rightOption
    var activationMode: ActivationMode = .pushToTalk
    var deliveryMode: DeliveryMode = .pasteAtCursor

    /// Separator before the pasted text. Without this, dictating twice in a row
    /// produces "...one two three.This is the next one."
    var spacingMode: SpacingMode = .smart

    /// Words and phrases to bias recognition toward: names, jargon, project
    /// nouns. One per line, edited as free text because that is how people
    /// think about a word list.
    var customVocabulary: String = ""

    /// How many past transcripts to keep for recovery. In memory only.
    var historyLimit: Int = 20

    /// Persisted microphone choice, by stable UID. Empty means "system default",
    /// which is what most people want and what follows AirPods in and out.
    var inputDeviceUID: String = ""

    /// BCP-47 identifier, e.g. "en-US".
    var localeIdentifier: String = "en-US"

    /// Conservative regex pass that removes standalone filler words.
    var stripFillers: Bool = false
    /// Apple Intelligence cleanup pass. Off by default: it costs latency.
    var polishWithAppleIntelligence: Bool = false
    /// Hard ceiling on the cleanup pass. Exceeding it falls back to raw text.
    var polishTimeoutMilliseconds: Int = 1200

    /// Auto-stop after this long so a stuck key can't record forever.
    var maxDictationSeconds: Int = 120

    /// Ignore presses shorter than this; they are almost always accidental.
    var minimumDictationMilliseconds: Int = 200

    /// How long to keep the microphone open after the key is released, waiting
    /// for the final audio buffer. 0 disables it.
    var tailGraceMilliseconds: Int = 150

    /// How long to wait after pasting before restoring the previous clipboard.
    var pasteRestoreDelayMilliseconds: Int = 250

    /// Require the Accessibility API to confirm an editable focused field
    /// before pasting.
    ///
    /// On by default. A Cmd+V sent somewhere that does not take text is not a
    /// harmless no-op: in the Finder it duplicates a file, and everywhere else
    /// the transcript is then erased by the clipboard restore. The check fails
    /// open — anything it cannot classify is allowed — so the cost of enabling
    /// it is an occasional fall back to the clipboard, which loses nothing.
    var requireEditableField: Bool = true

    var showHUD: Bool = true
    var playSounds: Bool = false
    var launchAtLogin: Bool = false

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// `customVocabulary` split into terms, blank lines and padding removed.
    var vocabularyTerms: [String] {
        customVocabulary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Observable, auto-persisting preference store.
@MainActor
@Observable
final class AppSettings {
    private static let defaultsKey = "settings.v1"

    var triggerKey: TriggerKey
    var activationMode: ActivationMode
    var deliveryMode: DeliveryMode
    var spacingMode: SpacingMode
    var customVocabulary: String
    var historyLimit: Int
    var inputDeviceUID: String
    var localeIdentifier: String
    var stripFillers: Bool
    var polishWithAppleIntelligence: Bool
    var polishTimeoutMilliseconds: Int
    var maxDictationSeconds: Int
    var minimumDictationMilliseconds: Int
    var tailGraceMilliseconds: Int
    var pasteRestoreDelayMilliseconds: Int
    var requireEditableField: Bool
    var showHUD: Bool
    var playSounds: Bool
    var launchAtLogin: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loaded: SettingsData
        if let raw = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            loaded = decoded
        } else {
            loaded = SettingsData()
        }

        triggerKey = loaded.triggerKey
        activationMode = loaded.activationMode
        deliveryMode = loaded.deliveryMode
        spacingMode = loaded.spacingMode
        customVocabulary = loaded.customVocabulary
        historyLimit = loaded.historyLimit
        inputDeviceUID = loaded.inputDeviceUID
        localeIdentifier = loaded.localeIdentifier
        stripFillers = loaded.stripFillers
        polishWithAppleIntelligence = loaded.polishWithAppleIntelligence
        polishTimeoutMilliseconds = loaded.polishTimeoutMilliseconds
        maxDictationSeconds = loaded.maxDictationSeconds
        minimumDictationMilliseconds = loaded.minimumDictationMilliseconds
        tailGraceMilliseconds = loaded.tailGraceMilliseconds
        pasteRestoreDelayMilliseconds = loaded.pasteRestoreDelayMilliseconds
        requireEditableField = loaded.requireEditableField
        showHUD = loaded.showHUD
        playSounds = loaded.playSounds
        launchAtLogin = loaded.launchAtLogin

        armAutosave()
    }

    /// Immutable copy, safe to hand to non-main-actor code.
    var snapshot: SettingsData {
        SettingsData(
            triggerKey: triggerKey,
            activationMode: activationMode,
            deliveryMode: deliveryMode,
            spacingMode: spacingMode,
            customVocabulary: customVocabulary,
            historyLimit: historyLimit,
            inputDeviceUID: inputDeviceUID,
            localeIdentifier: localeIdentifier,
            stripFillers: stripFillers,
            polishWithAppleIntelligence: polishWithAppleIntelligence,
            polishTimeoutMilliseconds: polishTimeoutMilliseconds,
            maxDictationSeconds: maxDictationSeconds,
            minimumDictationMilliseconds: minimumDictationMilliseconds,
            tailGraceMilliseconds: tailGraceMilliseconds,
            pasteRestoreDelayMilliseconds: pasteRestoreDelayMilliseconds,
            requireEditableField: requireEditableField,
            showHUD: showHUD,
            playSounds: playSounds,
            launchAtLogin: launchAtLogin
        )
    }

    /// Re-arming observation loop: reading `snapshot` touches every stored
    /// property, so any mutation fires `onChange` exactly once, and we then
    /// re-register for the next one.
    private func armAutosave() {
        withObservationTracking {
            _ = snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.persist()
                self.armAutosave()
            }
        }
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
