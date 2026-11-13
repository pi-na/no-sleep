import AppKit
import NoSleepCore

/// Runs Go Dark from the app and undoes it on the first real keyboard, mouse or trackpad input,
/// the way a sleeping display used to wake up.
///
/// While dark it also holds a display assertion. Otherwise the idle timer could put the dimmed display
/// to sleep for real, and that is exactly what locks the session.
@MainActor
final class GoDarkSession {
    /// Input in the first moments after dimming is the tail of the click or ⌘D that started it.
    private static let grace: TimeInterval = 1.0

    private var saved: [DisplayBrightness.Level] = []
    private var dimmedAt: Date?
    private var timer: Timer?
    private let keepDisplayOn = PowerAssertion(
        .preventIdleDisplaySleep,
        reason: "No Sleep Go Dark: screen dimmed, not asleep, so the session doesn't lock"
    )

    var isDark: Bool { dimmedAt != nil }

    func start() {
        let levels = GoDark.run()
        // Pressed again while already dark: keep the brightness from before the first time.
        if !isDark { saved = levels }
        guard !saved.isEmpty else { return } // Fell back to display sleep; macOS wakes it on input.
        dimmedAt = Date()
        keepDisplayOn.set(true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForInput() }
        }
    }

    /// Restores the brightness and stops watching. Safe to call when not dark.
    func end() {
        timer?.invalidate()
        timer = nil
        keepDisplayOn.set(false)
        if isDark { DisplayBrightness.restore(saved) }
        saved = []
        dimmedAt = nil
    }

    private func checkForInput() {
        guard let dimmedAt else { return }
        let elapsed = Date().timeIntervalSince(dimmedAt)
        guard elapsed > Self.grace else { return }
        // Hardware input only (`hidSystemState`): events posted by automation don't wake the screen.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
        if idle < elapsed - Self.grace { end() }
    }

    private static let anyInput = CGEventType(rawValue: ~0)!
}
