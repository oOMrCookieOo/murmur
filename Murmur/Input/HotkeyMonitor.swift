import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// Raw trigger events. Interpreting them (hold vs. toggle) is the controller's
/// job, not the monitor's.
enum HotkeyEvent: Sendable {
    case triggerDown
    case triggerUp
    /// Escape pressed while a dictation was in flight.
    case cancel
}

enum HotkeyMonitorError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            return "Could not install the keyboard listener. Grant Murmur "
                 + "Accessibility and Input Monitoring access in System Settings."
        }
    }
}

/// Watches the global keyboard for the push-to-talk trigger.
///
/// Runs its `CFRunLoop` on a dedicated `.userInteractive` thread rather than the
/// main run loop. An event tap whose run loop stalls gets forcibly disabled by
/// the system, and the main thread of a SwiftUI app stalls all the time (window
/// resizing, menu tracking). Keeping the tap off the main thread is what makes
/// key-down reliably instant.
///
/// `@unchecked Sendable`: cross-thread mutable state is confined to the two
/// `Synchronization` primitives and `lifecycleLock` below.
final class HotkeyMonitor: @unchecked Sendable {

    private let handler: @Sendable (HotkeyEvent) -> Void

    /// Read on the tap thread for every modifier event, written from the main
    /// actor when the user changes the preference.
    private let trigger = Mutex<TriggerKey>(.rightOption)

    /// Lets the tap thread decide synchronously whether to swallow Escape.
    /// Must be synchronous: returning from the callback is what consumes the
    /// event, so we cannot hop to another actor to decide.
    private let capturing = Atomic<Bool>(false)

    private let lifecycleLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    /// The `passRetained` pointer handed to the C callback. Held so the retain
    /// can be balanced exactly once when the run loop exits.
    private var callbackToken: UnsafeMutableRawPointer?

    init(handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        self.handler = handler
    }

    // MARK: - Configuration

    func setTrigger(_ key: TriggerKey) {
        trigger.withLock { $0 = key }
    }

    /// Tells the monitor a dictation is in flight, which enables Escape capture.
    func setCapturing(_ value: Bool) {
        capturing.store(value, ordering: .releasing)
    }

    // MARK: - Lifecycle

    /// Installs the event tap. Throws if the required permissions are missing,
    /// which is the signal to show the onboarding UI.
    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard tap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)

        // `passRetained`, not `passUnretained`: the C callback may be executing
        // on the tap thread at the moment the last Swift reference is dropped,
        // and an unretained pointer would then be a use-after-free. The retain
        // is balanced once the run loop exits, below.
        let token = Unmanaged.passRetained(self).toOpaque()

        // `.defaultTap` (not `.listenOnly`) because Escape has to be swallowed.
        // Returns nil when Accessibility access has not been granted.
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: token
        ) else {
            Unmanaged<HotkeyMonitor>.fromOpaque(token).release()
            throw HotkeyMonitorError.tapCreationFailed
        }

        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        callbackToken = token

        // `start()` must not return until the thread has published its run loop.
        // Otherwise a `stop()` arriving first finds `loop == nil`, cleans up
        // nothing, and leaves an orphaned thread running a live event tap.
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [self] in threadMain(ready: ready) }
        thread.name = "com.mrcookie.Murmur.hotkey"
        thread.qualityOfService = .userInteractive

        lifecycleLock.unlock()
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        lifecycleLock.lock()   // re-taken so the outer `defer` stays balanced

        Log.input.info("Hotkey tap installed")
    }

    /// Body of the dedicated tap thread.
    private func threadMain(ready: DispatchSemaphore) {
        let current = CFRunLoopGetCurrent()

        lifecycleLock.lock()
        loop = current
        let threadTap = tap
        let threadSource = source
        lifecycleLock.unlock()

        ready.signal()

        guard let threadTap, let threadSource else { return }

        CFRunLoopAddSource(current, threadSource, .commonModes)
        CGEvent.tapEnable(tap: threadTap, enable: true)

        CFRunLoopRun()   // returns only once stop() calls CFRunLoopStop

        // The callback can no longer fire, so the retain taken in start() is
        // balanced here — exactly once.
        lifecycleLock.lock()
        let token = callbackToken
        callbackToken = nil
        lifecycleLock.unlock()
        if let token { Unmanaged<HotkeyMonitor>.fromOpaque(token).release() }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let tap, let source, let loop else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        // Without invalidating the port the tap can outlive the run loop.
        CFMachPortInvalidate(tap)
        CFRunLoopStop(loop)

        self.tap = nil
        self.source = nil
        self.loop = nil
    }

    // MARK: - Tap callback

    /// Called on the dedicated tap thread. Returning `nil` consumes the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that take too long, or on certain user
            // input. Re-arming here is what keeps the app working across sleep,
            // fast user switching and secure input fields.
            lifecycleLock.lock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lifecycleLock.unlock()
            Log.input.warning("Event tap disabled by system; re-enabled")

            // Any flagsChanged that happened while the tap was dead is gone. If
            // that was the trigger release, recording would otherwise run to the
            // auto-stop limit and then paste two minutes of audio. Synthesising
            // the release is the safe interpretation.
            if capturing.load(ordering: .acquiring) {
                handler(.triggerUp)
            }
            return nil

        case .flagsChanged:
            let key = trigger.withLock { $0 }
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else {
                return pass
            }
            handler(key.isHeld(in: event.flags) ? .triggerDown : .triggerUp)
            // Deliberately never swallowed. Right Option is a real modifier used
            // for alternate characters; consuming it would break typing.
            return pass

        case .keyDown:
            guard capturing.load(ordering: .acquiring),
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
            else { return pass }
            handler(.cancel)
            // Swallowed so Escape cancels the dictation without also closing a
            // sheet or clearing a field in the app underneath.
            return nil

        default:
            return pass
        }
    }
}

/// Top-level because a `CGEventTapCallBack` is a C function pointer and cannot
/// capture context; the instance arrives via `userInfo`.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
