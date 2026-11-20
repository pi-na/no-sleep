import AppKit
import Observation
import QuartzCore

/// A faint glow along the bottom edge of every screen while No Sleep is keeping the Mac awake,
/// so the state is visible out of the corner of your eye without opening the menu.
///
/// One click-through window per screen, above the Dock, on every Space (full-screen ones too).
/// The glow is a static gradient layer: once drawn, the WindowServer composites it and the app
/// does no work at all until the state, the settings or the screens change.
@MainActor
final class AwakeGlow {
    /// Height of the glow band, in points.
    static let height: CGFloat = 28

    private let controller: SleepController
    private var windows: [GlowWindow] = []

    init(controller: SleepController) {
        self.controller = controller
    }

    func start() {
        observe()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows.forEach { $0.orderOut(nil) }
                self?.windows = []
                self?.apply()
            }
        }
    }

    func stop() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// Re-applies whenever anything `apply()` reads on the controller changes.
    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    private func apply() {
        let visible = controller.isActive && controller.glowEnabled
        let color = controller.glowColor
        let opacity = controller.glowOpacity
        guard visible else {
            windows.forEach { $0.orderOut(nil) }
            return
        }
        if windows.count != NSScreen.screens.count {
            windows.forEach { $0.orderOut(nil) }
            windows = NSScreen.screens.map(GlowWindow.init(screen:))
        }
        for window in windows {
            window.setGlow(color: color, opacity: opacity)
            window.orderFrontRegardless()
        }
    }
}

private final class GlowWindow: NSWindow {
    private let gradient = CAGradientLayer()

    init(screen: NSScreen) {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: AwakeGlow.height)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above the Dock (and full-screen apps), below menus and alerts.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Keep it out of screenshots and screen sharing where macOS honours this.
        sharingType = .none
        animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        gradient.frame = view.bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Layer coordinates are y-up: (0.5, 0) is the bottom edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = [0, 0.35, 1]
        view.layer?.addSublayer(gradient)
        contentView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setGlow(color: NSColor, opacity: Double) {
        let base = color.usingColorSpace(.sRGB) ?? color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = [
            base.withAlphaComponent(opacity).cgColor,
            base.withAlphaComponent(opacity * 0.4).cgColor,
            base.withAlphaComponent(0).cgColor,
        ]
        CATransaction.commit()
    }
}
