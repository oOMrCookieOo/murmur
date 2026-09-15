import AppKit
import SwiftUI

/// A borderless panel that cannot take focus.
///
/// Both overrides are essential: if the HUD could become key, showing it would
/// steal focus from the app the user is dictating into, and the paste would
/// land in the wrong place — or nowhere.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating dictation indicator that appears next to the cursor.
@MainActor
final class HUDController {

    /// Owned by `HUDView`, which knows how much room its shadow needs.
    private static var size: NSSize { HUDView.windowSize }

    private var panel: HUDPanel?

    /// Strong, and deliberately so.
    ///
    /// This was `weak`, which read as cycle protection it did not provide: the
    /// panel's hosting view holds `HUDView`, which holds the controller
    /// strongly, so the cycle exists either way. Both objects live for the
    /// lifetime of the app, so the honest thing is to say so rather than
    /// decorate it with a keyword that changes nothing.
    private var controller: DictationController?

    func attach(controller: DictationController) {
        self.controller = controller
    }

    func show(position: HUDPosition) {
        guard let controller else { return }

        let panel = panel ?? makePanel(for: controller)
        self.panel = panel

        panel.setFrameOrigin(Self.origin(for: position, size: Self.size))
        // `orderFrontRegardless`, never `makeKeyAndOrderFront`: the latter would
        // activate Murmur and pull focus away from the target app.
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel(for controller: DictationController) -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow; a window shadow would trace the
        // rectangular frame around it.
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // never intercept a click
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,                   // follows the user across Spaces
            .fullScreenAuxiliary,                // visible over full-screen apps
            .stationary,
            .ignoresCycle,
        ]

        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        // Liquid Glass samples what is behind the window, so the hosting view
        // must not paint an opaque background of its own.
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        return panel
    }

    /// Positions the HUD, always on the screen the pointer is currently on so it
    /// appears where the user is looking in a multi-display setup.
    private static func origin(for position: HUDPosition, size: NSSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return pointer }

        let inset: CGFloat = 8
        var origin: NSPoint

        switch position {
        case .bottomCentre:
            // Clear of the Dock, and high enough to read at a glance without
            // covering what is being dictated into.
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 96
            )
        case .nearCursor:
            origin = NSPoint(x: pointer.x + 18, y: pointer.y - size.height - 18)
        }

        origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - size.width - inset)
        origin.y = min(max(origin.y, visible.minY + inset), visible.maxY - size.height - inset)
        return origin
    }
}
