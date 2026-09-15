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

    /// How long to wait after pasting before restoring the previous clipboard.
    var pasteRestoreDelayMilliseconds: Int = 250

    /// Require the Accessibility API to confirm an editable focused field
    /// before pasting. More cautious, but produces false negatives in some
    /// Electron apps, so it is off by default.
    var requireEditableField: Bool = false

    var showHUD: Bool = true
    var playSounds: Bool = false
    var launchAtLogin: Bool = false

    var locale: Locale { Locale(identifier: localeIdentifier) }
}

/// Observable, auto-persisting preference store.
@MainActor
@Observable
final class AppSettings {
    private static let defaultsKey = "settings.v1"

    var triggerKey: TriggerKey
    var activationMode: ActivationMode
    var deliveryMode: DeliveryMode
    var localeIdentifier: String
    var stripFillers: Bool
    var polishWithAppleIntelligence: Bool
    var polishTimeoutMilliseconds: Int
    var maxDictationSeconds: Int
    var minimumDictationMilliseconds: Int
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
        localeIdentifier = loaded.localeIdentifier
        stripFillers = loaded.stripFillers
        polishWithAppleIntelligence = loaded.polishWithAppleIntelligence
        polishTimeoutMilliseconds = loaded.polishTimeoutMilliseconds
        maxDictationSeconds = loaded.maxDictationSeconds
        minimumDictationMilliseconds = loaded.minimumDictationMilliseconds
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
            localeIdentifier: localeIdentifier,
            stripFillers: stripFillers,
            polishWithAppleIntelligence: polishWithAppleIntelligence,
            polishTimeoutMilliseconds: polishTimeoutMilliseconds,
            maxDictationSeconds: maxDictationSeconds,
            minimumDictationMilliseconds: minimumDictationMilliseconds,
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
