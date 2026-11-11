import AppKit
import NoSleepCore
import SwiftUI

@main
struct NoSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                controller: appDelegate.controller,
                integrations: appDelegate.integrations,
                openSettings: { appDelegate.openSettings() }
            )
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SleepController()
    let integrations = Integrations()
    private let settingsWindow = SettingsWindowController()
    private var quittingFromMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.runIfRequested(controller: controller, integrations: integrations) {
            exit(0)
        }

        // Only one copy may manage sleep settings.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: NoSleepConstants.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty, Bundle.main.bundleIdentifier == NoSleepConstants.bundleIdentifier {
            NSApp.terminate(nil)
            return
        }

        writePIDFile()
        integrations.refresh()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown(forget: quittingFromMenu)
        try? FileManager.default.removeItem(at: NoSleepPaths.appPIDFile)
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func openSettings() {
        // Close the menu bar panel first.
        if let panel = NSApp.keyWindow, panel is NSPanel { panel.close() }
        integrations.refresh()
        settingsWindow.show(controller: controller, integrations: integrations)
    }

    /// Mute and turn the screen off. Closes the menu first so the click doesn't wake the display.
    func goDark() {
        if let panel = NSApp.keyWindow, panel is NSPanel { panel.close() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
            GoDark.run()
        }
    }

    func quitFromMenu() {
        quittingFromMenu = true
        NSApp.terminate(nil)
    }

    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = ProcessInspector.snapshot(of: pid)?.startTime ?? 0
        let url = NoSleepPaths.appPIDFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid) \(start)\n".write(to: url, atomically: true, encoding: .utf8)
    }
}
