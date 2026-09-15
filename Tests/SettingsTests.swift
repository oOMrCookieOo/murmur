import Foundation

/// Regression tests for settings persistence.
///
/// Swift's synthesised `Decodable` ignores property default values and throws
/// `keyNotFound` for any absent key. Combined with a `try?` at the call site,
/// that meant adding one new setting silently reset **every** preference the
/// user had. It went unnoticed through six releases because it produces no
/// error, no log line and no UI signal.
///
/// The fixture below is deliberately an OLD payload: it contains only the keys
/// that existed before a batch of settings were added. If someone adds a field
/// and forgets the `decodeIfPresent` line, this test fails instead of the
/// user's preferences.
///
/// Run with `make test`.
@main
struct SettingsTests {

    /// Exactly the keys an early build wrote, with deliberately non-default values.
    static let legacyPayload = """
    {
      "triggerKey": "rightCommand",
      "activationMode": "toggle",
      "deliveryMode": "clipboardOnly",
      "localeIdentifier": "fr-FR",
      "stripFillers": true,
      "polishWithAppleIntelligence": true,
      "polishTimeoutMilliseconds": 2000,
      "maxDictationSeconds": 600,
      "minimumDictationMilliseconds": 400,
      "pasteRestoreDelayMilliseconds": 500,
      "requireEditableField": false,
      "showHUD": false,
      "playSounds": true,
      "launchAtLogin": true
    }
    """

    static func main() {
        var failures = 0

        func check(_ label: String, _ condition: Bool) {
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL")  \(label)")
        }

        print("=== an old payload must not wipe the user's settings ===")

        guard let data = legacyPayload.data(using: .utf8) else {
            print("FAIL  fixture is not valid UTF-8")
            exit(1)
        }

        let decoded: SettingsData
        do {
            decoded = try JSONDecoder().decode(SettingsData.self, from: data)
        } catch {
            print("FAIL  decoding threw, so every preference would have been reset: \(error)")
            exit(1)
        }

        // Values the user actually chose must survive.
        check("triggerKey preserved",       decoded.triggerKey == .rightCommand)
        check("activationMode preserved",   decoded.activationMode == .toggle)
        check("deliveryMode preserved",     decoded.deliveryMode == .clipboardOnly)
        check("locale preserved",           decoded.localeIdentifier == "fr-FR")
        check("stripFillers preserved",     decoded.stripFillers)
        check("polish preserved",           decoded.polishWithAppleIntelligence)
        check("polishTimeout preserved",    decoded.polishTimeoutMilliseconds == 2000)
        check("maxDictation preserved",     decoded.maxDictationSeconds == 600)
        check("minimumDictation preserved", decoded.minimumDictationMilliseconds == 400)
        check("pasteRestore preserved",     decoded.pasteRestoreDelayMilliseconds == 500)
        check("requireEditable preserved",  decoded.requireEditableField == false)
        check("showHUD preserved",          decoded.showHUD == false)
        check("playSounds preserved",       decoded.playSounds)
        check("launchAtLogin preserved",    decoded.launchAtLogin)

        // Keys added later must fall back to their defaults, not blow up.
        let defaults = SettingsData()
        check("spacingMode defaulted",      decoded.spacingMode == defaults.spacingMode)
        check("customVocabulary defaulted", decoded.customVocabulary == defaults.customVocabulary)
        check("historyLimit defaulted",     decoded.historyLimit == defaults.historyLimit)
        check("inputDeviceUID defaulted",   decoded.inputDeviceUID == defaults.inputDeviceUID)
        check("tailGrace defaulted",        decoded.tailGraceMilliseconds == defaults.tailGraceMilliseconds)
        check("autoStopOnSilence defaulted", decoded.autoStopOnSilence == defaults.autoStopOnSilence)
        check("silenceTimeout defaulted",   decoded.silenceTimeoutMilliseconds == defaults.silenceTimeoutMilliseconds)
        check("hudPosition defaulted",      decoded.hudPosition == defaults.hudPosition)

        print("\n=== an empty object must yield pure defaults, not an error ===")
        if let empty = "{}".data(using: .utf8),
           let fromEmpty = try? JSONDecoder().decode(SettingsData.self, from: empty) {
            check("empty object decodes", fromEmpty == defaults)
        } else {
            check("empty object decodes", false)
        }

        print("\n=== a full round trip must be lossless ===")
        if let encoded = try? JSONEncoder().encode(decoded),
           let round = try? JSONDecoder().decode(SettingsData.self, from: encoded) {
            check("round trip lossless", round == decoded)
        } else {
            check("round trip lossless", false)
        }

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
    }
}
