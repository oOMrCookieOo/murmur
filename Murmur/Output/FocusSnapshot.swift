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

    /// Resolves the pid back to a running app, rejecting a recycled pid.
    ///
    /// pids are reused, and while the window here is only seconds, comparing
    /// the bundle identifier as well costs nothing and removes the chance of
    /// pasting into an unrelated app that inherited the number.
    @MainActor
    private var runningApp: NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        guard app.bundleIdentifier == bundleIdentifier else {
            Log.output.warning("pid \(processIdentifier, privacy: .public) was reused by another app")
            return nil
        }
        return app
    }

    @MainActor
    var isStillFrontmost: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == processIdentifier
            && front.bundleIdentifier == bundleIdentifier
    }

    @MainActor
    var isStillRunning: Bool { runningApp != nil }

    /// Brings the remembered app back to the front and *waits* for it.
    ///
    /// `NSRunningApplication.activate()` returns as soon as the request is
    /// accepted, not when activation completes — `frontmostApplication` keeps
    /// reporting the old app for tens to hundreds of milliseconds afterwards.
    /// Checking immediately would therefore almost always report failure, so we
    /// poll until it actually lands.
    ///
    /// - Returns: whether the app is frontmost by the time we give up.
    @MainActor
    @discardableResult
    func reactivateAndWait(timeoutMilliseconds: Int = 300) async -> Bool {
        guard let app = runningApp else { return false }
        guard app.activate() else { return false }

        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            // `try? await Task.sleep` returns instantly once cancelled, so
            // without this the loop busy-spins the main actor for its full
            // timeout.
            if Task.isCancelled { return false }
            if isStillFrontmost { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isStillFrontmost
    }

    var displayName: String { localizedName ?? bundleIdentifier ?? "the focused app" }
}
