import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Gets transcribed text into the app the user was working in.
///
/// ## Why paste instead of synthesising keystrokes
///
/// Typing the text character by character via `CGEvent` breaks on non-ASCII,
/// races with autocomplete, and takes ~1 ms per character. A single Cmd+V is
/// atomic, preserves newlines, and works identically in native apps, Electron,
/// web views and terminals, because every one of them implements paste.
///
/// The cost is that we have to borrow the clipboard, which is why every path
/// through here restores it.
@MainActor
enum TextInjector {

    enum Delivery: Sendable, Equatable {
        case pasted
        /// Text is on the clipboard; `reason` is nil when that is what the user asked for.
        case leftOnClipboard(reason: String?)
    }

    static func deliver(
        _ text: String,
        to target: FocusSnapshot?,
        settings: SettingsData
    ) async -> Delivery {
        guard !text.isEmpty else { return .leftOnClipboard(reason: "Nothing was transcribed") }

        if settings.deliveryMode == .clipboardOnly {
            writeToClipboardWithoutRestoring(text)
            return .leftOnClipboard(reason: nil)
        }

        if let refusal = pasteBlocker(for: target, settings: settings) {
            // Falling back to the clipboard rather than dropping the text is the
            // whole point: the user said words, the words must survive.
            writeToClipboardWithoutRestoring(text)
            return .leftOnClipboard(reason: refusal)
        }

        return await paste(text, settings: settings)
    }

    // MARK: - Safety

    /// Returns a human-readable reason to skip pasting, or nil if pasting is safe.
    private static func pasteBlocker(for target: FocusSnapshot?, settings: SettingsData) -> String? {
        guard let target else { return "No app was focused" }

        guard AXIsProcessTrusted() else { return "Accessibility access not granted" }

        if !target.isStillFrontmost {
            guard target.isStillRunning else { return "\(target.displayName) quit" }
            // Focus moved while the user was talking. Put it back rather than
            // pasting into whatever happens to be in front now.
            target.reactivate()
            if !target.isStillFrontmost {
                return "Focus moved to another app"
            }
        }

        if settings.requireEditableField, !focusedElementLooksEditable(pid: target.processIdentifier) {
            return "No editable field is focused"
        }

        return nil
    }

    /// Best-effort Accessibility check for whether the focused element takes text.
    ///
    /// Deliberately lenient — it returns true whenever it cannot tell. Many apps
    /// (Electron, terminals, some Java toolkits) expose a focused element that
    /// looks inert but pastes perfectly well, so treating "unknown" as "unsafe"
    /// would block legitimate pastes. Only clearly non-text roles are rejected,
    /// and this whole check is opt-in via `requireEditableField`.
    private static func focusedElementLooksEditable(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue
        else { return true }

        let element = focusedValue as! AXUIElement

        // A settable value attribute is the strongest signal of an editable field.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String
        else { return true }

        let definitelyNotText: Set<String> = [
            kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXMenuItemRole, kAXMenuBarItemRole, kAXImageRole,
            kAXSliderRole, kAXProgressIndicatorRole,
        ]
        return !definitelyNotText.contains(role)
    }

    // MARK: - Clipboard

    private static func writeToClipboardWithoutRestoring(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Paste

    private static func paste(_ text: String, settings: SettingsData) async -> Delivery {
        let pasteboard = NSPasteboard.general

        let previous = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        // `.string` preserves newlines exactly, so multi-line dictation lands
        // as multiple lines rather than one run-on paragraph.
        guard pasteboard.setString(text, forType: .string) else {
            return .leftOnClipboard(reason: "Could not write to the clipboard")
        }
        let ourChangeCount = pasteboard.changeCount

        // If the trigger key is still physically held, its modifier bit would be
        // OR'd into our synthetic event and the target would see Ctrl+Cmd+V or
        // similar. Wait briefly for the keyboard to settle.
        await waitForModifiersToClear(timeoutMilliseconds: 60)

        guard postCommandV() else {
            previous.restore(to: pasteboard, onlyIfUnchangedFrom: ourChangeCount)
            return .leftOnClipboard(reason: "Could not send the paste keystroke")
        }

        // Give the target app time to actually read the pasteboard before we
        // put the old contents back. Too short and the paste lands empty; too
        // long and the user notices their clipboard is briefly wrong.
        try? await Task.sleep(for: .milliseconds(settings.pasteRestoreDelayMilliseconds))
        previous.restore(to: pasteboard, onlyIfUnchangedFrom: ourChangeCount)

        return .pasted
    }

    private static func postCommandV() -> Bool {
        // `.combinedSessionState` so the synthetic event inherits the session's
        // keyboard state rather than a pristine one.
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }

        // Assigning flags outright (rather than OR-ing) guarantees exactly
        // Command is set, whatever the user's fingers are doing.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // `.cghidEventTap` posts at the lowest level, which is what makes this
        // work in terminals and Electron apps that read HID state directly.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func waitForModifiersToClear(timeoutMilliseconds: Int) async {
        let blocking: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)

        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(blocking).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Log.output.info("Modifiers still held at paste time; pasting anyway")
    }
}
