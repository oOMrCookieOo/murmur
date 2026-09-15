import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import os

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
/// through here restores it — including the failure paths.
///
/// ## The governing rule
///
/// The user's words must never be lost, and the user's clipboard must never be
/// destroyed. Where those two conflict with pasting, pasting loses.
@MainActor
enum TextInjector {

    /// Outcome plus the instant the paste keystroke was posted.
    ///
    /// The instant matters for measurement: `deliver` does not return until the
    /// clipboard has been restored ~250 ms later, but the text appears on
    /// screen the moment Cmd+V goes out. Timing the return value would
    /// overstate perceived latency by the whole restore delay.
    struct DeliveryReport: Sendable {
        let delivery: Delivery
        let pastedAt: ContinuousClock.Instant?

        init(_ delivery: Delivery, pastedAt: ContinuousClock.Instant? = nil) {
            self.delivery = delivery
            self.pastedAt = pastedAt
        }
    }

    enum Delivery: Sendable, Equatable {
        case pasted
        /// Text is on the clipboard. `reason` is nil when that is what the user asked for.
        case leftOnClipboard(reason: String?)
        /// Nothing could be delivered. The text is NOT on the clipboard.
        case failed(reason: String)
    }

    static func deliver(
        _ text: String,
        to target: FocusSnapshot?,
        settings: SettingsData
    ) async -> DeliveryReport {
        guard !text.isEmpty else { return DeliveryReport(.failed(reason: "Nothing was transcribed")) }

        if settings.deliveryMode == .clipboardOnly {
            return DeliveryReport(writeToClipboardWithoutRestoring(text)
                ? .leftOnClipboard(reason: nil)
                : .failed(reason: "Could not write to the clipboard"))
        }

        if let refusal = await pasteBlocker(for: target, settings: settings) {
            // Falling back to the clipboard rather than dropping the text is the
            // whole point: the user said words, the words must survive.
            return DeliveryReport(writeToClipboardWithoutRestoring(text)
                ? .leftOnClipboard(reason: refusal)
                : .failed(reason: "Could not write to the clipboard"))
        }

        let separator = leadingSeparator(for: target, settings: settings)
        return await paste(separator + text, to: target, settings: settings)
    }

    // MARK: - Spacing

    /// When the last paste happened, and where, so consecutive dictations can be
    /// separated even in apps whose text position we cannot read.
    private static var lastPasteTarget: (pid: pid_t, at: ContinuousClock.Instant)?

    private static func leadingSeparator(for target: FocusSnapshot?, settings: SettingsData) -> String {
        switch settings.spacingMode {
        case .never:
            return ""
        case .always:
            return " "
        case .smart:
            guard let target else { return "" }
            // Ask the app directly where the caret is. This is the only way to
            // get it right in the general case — the user may have clicked
            // somewhere else entirely between dictations.
            if let needsSpace = caretFollowsNonWhitespace(pid: target.processIdentifier) {
                return needsSpace ? " " : ""
            }
            // Terminals and many Electron views do not expose a caret offset.
            // Fall back to the case this actually matters for: dictating
            // repeatedly into the same app without pausing.
            if let last = lastPasteTarget,
               last.pid == target.processIdentifier,
               ContinuousClock.now - last.at < .seconds(30) {
                return " "
            }
            return ""
        }
    }

    /// Whether the character immediately before the caret is a non-space.
    ///
    /// Returns nil when the app does not expose enough Accessibility detail to
    /// tell, which is common in terminals and web views.
    private static func caretFollowsNonWhitespace(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var caret = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue as AnyObject, to: AXValue.self), .cfRange, &caret) else {
            return nil
        }
        // Start of the field: nothing to separate from.
        guard caret.location > 0 else { return false }

        var previousCharacter = CFRange(location: caret.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previousCharacter) else { return nil }

        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXStringForRangeParameterizedAttribute as CFString,
                  parameter,
                  &text
              ) == .success,
              let string = text as? String,
              let character = string.first
        else { return nil }

        return !character.isWhitespace && !character.isNewline
    }

    // MARK: - Safety

    /// Returns a human-readable reason to skip pasting, or nil if pasting is safe.
    private static func pasteBlocker(for target: FocusSnapshot?, settings: SettingsData) async -> String? {
        guard let target else { return "No app was focused" }

        guard AXIsProcessTrusted() else { return "Accessibility access not granted" }

        // Secure Event Input locks out synthetic keystrokes entirely: a sudo
        // prompt in Terminal, a password field, or the well-known stuck-secure
        // -input state. Cmd+V would be silently swallowed and we would then
        // restore the clipboard over the transcript, losing it outright.
        if IsSecureEventInputEnabled() {
            return "A password field is active"
        }

        if !target.isStillFrontmost {
            guard target.isStillRunning else { return "\(target.displayName) quit" }
            // Focus moved while the user was talking. Put it back rather than
            // pasting into whatever happens to be in front now.
            guard await target.reactivateAndWait() else {
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
    /// would block legitimate pastes. Only clearly non-text roles are rejected.
    ///
    /// What it does buy: it stops a Cmd+V going to the Finder, where paste means
    /// "duplicate a file" rather than "insert text".
    private static func focusedElementLooksEditable(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)

        // Without this, a beachballing target blocks each cross-process AX call
        // for the ~6 s default, freezing our main actor and the HUD with it.
        // A timeout surfaces as an error, which the fail-open guards treat as
        // "allow", so the worst case is the behaviour we had before.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue
        else { return true }

        // The value crosses a process boundary from another app's AX server; a
        // non-conforming one can hand back a CFString or CFNull. An unchecked
        // downcast would be a hard trap, i.e. a crash caused by someone else's
        // bug.
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return true }
        let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

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

    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Supplies the transcript lazily, so we learn the exact moment a reader
    /// takes it.
    ///
    /// This is how the restore stops being a guess. Instead of sleeping a fixed
    /// 250 ms and hoping the target read the clipboard first, we put the old
    /// contents back the instant the read actually happens.
    ///
    /// It is an optimisation, never a correctness requirement, because it can
    /// be defeated: the first read caches the value and no later read re-fires
    /// the callback, so any clipboard manager that reads on change consumes the
    /// signal before the target app does. When that happens we simply fall back
    /// to the timed restore, which is what the app did before.
    private final class TranscriptDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let text: String
        private let lastRead = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

        init(text: String) {
            self.text = text
            super.init()
        }

        /// When the transcript was most recently handed to a reader.
        var lastReadAt: ContinuousClock.Instant? { lastRead.withLock { $0 } }

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            if type == concealedType {
                item.setString("", forType: type)
                return
            }
            item.setString(text, forType: type)
            lastRead.withLock { $0 = .now }
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
    }

    /// A pasteboard item that yields the transcript on demand and carries the
    /// community-standard "do not archive me" marker.
    private static func transcriptItem(provider: TranscriptDataProvider) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string, concealedType])
        return item
    }

    /// Waits for the transcript to actually be read, up to `timeoutMilliseconds`.
    /// - Returns: whether a read was observed after `postedAt`.
    private static func waitForRead(
        from provider: TranscriptDataProvider,
        after postedAt: ContinuousClock.Instant,
        timeoutMilliseconds: Int
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            // Only reads that happen after the keystroke count. An earlier one
            // is a clipboard manager, not the target app.
            if let read = provider.lastReadAt, read > postedAt { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }

    @discardableResult
    private static func writeToClipboardWithoutRestoring(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Log.output.error("Could not write the transcript to the clipboard")
            return false
        }
        return true
    }

    // MARK: - Paste

    private static func paste(
        _ text: String,
        to target: FocusSnapshot?,
        settings: SettingsData
    ) async -> DeliveryReport {
        let pasteboard = NSPasteboard.general

        let previous = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        // `.string` preserves newlines exactly, so multi-line dictation lands
        // as multiple lines rather than one run-on paragraph.
        //
        // Also tagged concealed. Here the clipboard is pure plumbing — we put
        // the text back seconds later — but without the tag every dictation is
        // archived by clipboard managers and pushed to the user's other devices
        // by Universal Clipboard. For an app whose whole point is that speech
        // never leaves the machine, that would be a real leak.
        //
        // Only on this path: in clipboard-only mode the clipboard IS the
        // deliverable, and suppressing history there would be wrong.
        let provider = TranscriptDataProvider(text: text)
        guard pasteboard.writeObjects([transcriptItem(provider: provider)]) else {
            // The clipboard has already been cleared, so the user's contents are
            // gone unless we put them back right now.
            previous.restore(to: pasteboard, onlyIfUnchangedFrom: pasteboard.changeCount)
            return DeliveryReport(.failed(reason: "Could not write to the clipboard"))
        }
        let ourChangeCount = pasteboard.changeCount

        // If the trigger key is still physically held, its modifier bit would be
        // OR'd into our synthetic event and the target would see Ctrl+Cmd+V or
        // similar. Wait briefly for the keyboard to settle.
        await waitForModifiersToClear(timeoutMilliseconds: 60)

        // Re-assert the target immediately before posting. Everything above can
        // suspend, and a Cmd-Tab in that window would send the paste — and the
        // user's text — into the wrong app.
        if let target, !target.isStillFrontmost {
            previous.restore(to: pasteboard, onlyIfUnchangedFrom: ourChangeCount)
            _ = writeToClipboardWithoutRestoring(text)
            return DeliveryReport(.leftOnClipboard(reason: "Focus moved to another app"))
        }

        let pastedAt = ContinuousClock.now
        guard postCommandV() else {
            previous.restore(to: pasteboard, onlyIfUnchangedFrom: ourChangeCount)
            _ = writeToClipboardWithoutRestoring(text)
            return DeliveryReport(.leftOnClipboard(reason: "Could not send the paste keystroke"))
        }

        // Restore as soon as the target has actually taken the text. Falling
        // back to the full delay keeps the old behaviour when the read cannot
        // be observed, so this can only ever be faster or the same.
        let confirmed = await waitForRead(
            from: provider,
            after: pastedAt,
            timeoutMilliseconds: settings.pasteRestoreDelayMilliseconds
        )
        if !confirmed {
            Log.output.info("Paste read not observed; restoring on the timer instead")
        }
        previous.restore(to: pasteboard, onlyIfUnchangedFrom: ourChangeCount)

        if let target { lastPasteTarget = (target.processIdentifier, .now) }
        return DeliveryReport(.pasted, pastedAt: pastedAt)
    }

    private static func postCommandV() -> Bool {
        // `.privateState`, not `.combinedSessionState`: a private source carries
        // its own modifier state, so the flags we assign below are authoritative
        // and cannot be merged with whatever the user is physically holding.
        guard let source = CGEventSource(stateID: .privateState) else { return false }

        // Do not suppress the user's real keystrokes after our synthetic ones;
        // the default 0.25 s interval would swallow whatever they type next.
        source.localEventsSuppressionInterval = 0

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }

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
            // Without this the loop would busy-spin: `try?` swallows the
            // cancellation error and Task.sleep returns immediately once
            // cancelled.
            if Task.isCancelled { return }

            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(blocking).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Log.output.info("Modifiers still held at paste time; pasting anyway")
    }
}
