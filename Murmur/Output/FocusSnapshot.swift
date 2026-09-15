import AppKit

/// Remembers which app was frontmost when dictation started, so the transcript
/// goes where the user was actually typing — not wherever focus drifted to
/// while they were talking.
struct FocusSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    @MainActor
    static func captureFrontmost() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        // Never target ourselves. The HUD is a non-activating panel so this
        // should not happen, but a Settings window would make it possible.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        return FocusSnapshot(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    @MainActor
    var isStillFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    @MainActor
    var isStillRunning: Bool {
        NSRunningApplication(processIdentifier: processIdentifier) != nil
    }

    /// Brings the remembered app back to the front. Returns false if it has quit.
    @MainActor
    @discardableResult
    func reactivate() -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return false }
        return app.activate()
    }

    var displayName: String { localizedName ?? bundleIdentifier ?? "the focused app" }
}
