import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Observation

enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined

    var isGranted: Bool { self == .granted }
}

/// The three Privacy & Security panes Murmur depends on.
enum PrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"
    /// Apple's internal name for the Input Monitoring pane.
    case inputMonitoring = "Privacy_ListenEvent"

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

/// Tracks the permissions Murmur needs and knows how to ask for each.
///
/// macOS gives no notification when a permission changes, so the values here
/// are refreshed on a timer while any permission UI is visible, and whenever
/// the app is reactivated.
@MainActor
@Observable
final class PermissionsModel {

    private(set) var microphone: PermissionStatus = .notDetermined
    /// Needed to post the paste keystroke and to create a modifying event tap.
    private(set) var accessibility = false
    /// Needed to observe the trigger key globally.
    private(set) var inputMonitoring = false

    init() { refresh() }

    var allGranted: Bool { microphone.isGranted && accessibility && inputMonitoring }

    /// Permissions required before dictation can work at all.
    var missingCritical: [String] {
        var missing: [String] = []
        if !microphone.isGranted { missing.append("Microphone") }
        if !accessibility { missing.append("Accessibility") }
        if !inputMonitoring { missing.append("Input Monitoring") }
        return missing
    }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }

    /// Shows the system microphone prompt the first time; afterwards macOS
    /// silently denies, so we send the user to Settings instead.
    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            Self.open(.microphone)
        }
        refresh()
    }

    /// Triggers the system "allow Accessibility access" prompt.
    func requestAccessibility() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`: that global is
        // an `Unmanaged<CFString>` var, which Swift 6 rejects as shared mutable
        // state. The string value is API-stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestInputMonitoring() {
        // Prompts once; returns immediately with the current state thereafter.
        _ = CGRequestListenEventAccess()
        refresh()
    }

    static func open(_ pane: PrivacyPane) {
        NSWorkspace.shared.open(pane.url)
    }
}
