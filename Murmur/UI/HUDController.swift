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

    private static let size = NSSize(width: 300, height: 64)

    private var panel: HUDPanel?
    private weak var controller: DictationController?

    func attach(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }

        let panel = panel ?? makePanel(for: controller)
        self.panel = panel

        panel.setFrameOrigin(Self.origin(near: NSEvent.mouseLocation, size: Self.size))
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
        panel.hasShadow = true
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
        panel.contentView = hosting
        return panel
    }

    /// Places the HUD just below-right of the cursor, clamped to the screen the
    /// cursor is actually on.
    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return point }

        let inset: CGFloat = 8
        var origin = NSPoint(x: point.x + 18, y: point.y - size.height - 18)

        origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - size.width - inset)
        origin.y = min(max(origin.y, visible.minY + inset), visible.maxY - size.height - inset)
        return origin
    }
}
