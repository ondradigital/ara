import AppKit
import SwiftUI
import os

/// A small borderless panel that floats above all apps without taking the
/// keyboard focus, used for the recording indicator and the vocabulary prompt.
final class FloatingPanel {
    enum Position {
        case top
        case bottom
    }

    /// The gap between the bottom screen edge and a bottom panel.
    private static let bottomMargin: CGFloat = 24

    private let position: Position
    private let isInteractive: Bool
    private var panel: NSPanel?
    private let logger = Logger(subsystem: "com.erikondra.Ara", category: "panel")

    /// An interactive panel takes clicks; otherwise clicks pass through to
    /// whatever is underneath.
    init(position: Position, isInteractive: Bool = false) {
        self.position = position
        self.isInteractive = isInteractive
    }

    /// Shows `content`, replacing whatever the panel showed before.
    func show(_ content: some View) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let host = FirstClickHostingView(rootView: content)
        // The frame is set by hand below. Letting the hosting view also drive the
        // window's size limits means it updates window constraints inside AppKit's
        // display cycle, which threw an NSGenericException when a display changed.
        // The view still reports its own size: with no options at all fittingSize
        // is zero, which placed the panel at size 0 and let it grow off the bottom.
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = host.intrinsicContentSize }
        if size.width < 1 || size.height < 1 { size = panel.frame.size }

        // The screen the user is working on, not necessarily the one with the menu bar.
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let area = screen.visibleFrame
            // The bottom position is measured from the screen edge, not from the
            // visible area, so it stays put whether the Dock is showing or hidden.
            let y = position == .top ? area.maxY - size.height - 12 : screen.frame.minY + Self.bottomMargin
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
            // Shows which display and area the panel was placed in, to trace a panel that sits too low.
            logger.notice("placed \(String(describing: self.position), privacy: .public) panel on \(screen.localizedName, privacy: .public): frame \(NSStringFromRect(screen.frame), privacy: .public), visible \(NSStringFromRect(area), privacy: .public), size \(NSStringFromSize(size), privacy: .public), y \(y, format: .fixed(precision: 0), privacy: .public)")
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = !isInteractive
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

/// The app is never frontmost when a panel is clicked, so without this the
/// first click would only be taken as "bring to front" and buttons would not react.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
