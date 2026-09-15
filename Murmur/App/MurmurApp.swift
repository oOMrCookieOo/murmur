import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(controller: delegate.controller)
        } label: {
            // Reading `phase` here is what makes the icon track state.
            Image(systemName: delegate.controller.phase.isRecording ? "mic.fill" : "mic")
        }
        // `.window` rather than `.menu` so the panel can show download
        // progress bars and multi-line warnings, which a menu cannot.
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView(controller: delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let permissions = PermissionsModel()
    private(set) lazy var controller = DictationController(
        settings: settings,
        permissions: permissions
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement: no Dock icon, no app switcher
        // entry, and crucially the app never steals focus when it shows the HUD.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        Log.app.info("Murmur launched")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Permissions can only change while we are in the background, so this
        // is the natural moment to re-read them.
        permissions.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
