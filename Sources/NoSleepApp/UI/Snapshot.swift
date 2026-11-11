import AppKit
import NoSleepCore
import SwiftUI

/// Debug helper: `NOSLEEP_SNAPSHOT=/some/dir NoSleep.app/Contents/MacOS/NoSleep` renders the menu
/// panel and the settings window to PNGs (light + dark) and exits. Never touches power settings.
@MainActor
enum Snapshot {
    static func runIfRequested(controller: SleepController, integrations: Integrations) -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["NOSLEEP_SNAPSHOT"] else { return false }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        controller.dryRun = true
        integrations.refresh()

        let scenario = ProcessInfo.processInfo.environment["NOSLEEP_SNAPSHOT_STATE"] ?? "off"
        switch scenario {
        case "on": controller.setEnabled(true)
        case "timer": controller.startTimer(duration: 5025)
        case "hot":
            controller.setEnabled(true)
            controller.simulateThermal(level: .serious, hotFor: 6 * 60 + 12)
        case "tripped":
            controller.setEnabled(true)
            controller.simulateThermal(level: .critical, hotFor: ThermalFailsafe.defaultLimit + 1)
        default: break
        }
        controller.refresh()
        controller.simulateLidApplied()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(
                MenuContentView(controller: controller, integrations: integrations, openSettings: {})
                    .background(Color(nsColor: .windowBackgroundColor)),
                appearance: appearance,
                to: output.appendingPathComponent("menu-\(scenario)-\(name).png")
            )
        }
        render(
            SettingsView(controller: controller, integrations: integrations)
                .frame(height: 980)
                .background(Color(nsColor: .windowBackgroundColor)),
            appearance: .aqua,
            to: output.appendingPathComponent("settings.png")
        )
        return true
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
