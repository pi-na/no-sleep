import AppKit
import ApplicationServices

/// Presses a network in the Wi‑Fi menu (Control Center) through Accessibility. For an iPhone in the
/// "Personal Hotspot" section that triggers Instant Hotspot, which wakes a locked iPhone over Bluetooth;
/// there's no public API for it. Works with the lid closed (verified on macOS 14.8).
///
/// Entries are found by `AXIdentifier == "wifi-network-<SSID>"`, which doesn't depend on the language;
/// the connected one has `AXValue == 1`. Every call blocks for a few seconds: run off the main thread.
enum InstantHotspot {
    enum Outcome: Equatable {
        case pressed
        case alreadyConnected
        case notFound
        case menuUnavailable
        case notTrusted
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens Privacy & Security → Accessibility.
    @MainActor
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func press(_ ssid: String) -> Outcome {
        guard isTrusted else { return .notTrusted }
        guard let menu = WiFiMenu.open() else { return .menuUnavailable }
        guard let entry = menu.waitForEntry(id: "wifi-network-\(ssid)", timeout: 5) else {
            menu.close()
            return .notFound
        }
        if entry.isChecked {
            menu.close()
            return .alreadyConnected
        }
        // Pressing a network closes the menu by itself.
        return AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success ? .pressed : .menuUnavailable
    }

    /// The checked network in the Wi‑Fi menu (opens and closes it). For when `WiFi.currentNetwork()`
    /// is hidden by macOS.
    static func connectedNetwork() -> String? {
        guard isTrusted, let menu = WiFiMenu.open() else { return nil }
        defer { menu.close() }
        // The list fills in gradually: wait for the checked entry itself, not just any entry.
        return menu.waitFor(timeout: 4) { $0.isChecked }.map { String($0.id.dropFirst("wifi-network-".count)) }
    }
}

/// The Wi‑Fi menu bar extra of Control Center and its open window.
private struct WiFiMenu {
    struct Entry {
        let element: AXUIElement
        let id: String
        let isChecked: Bool
    }

    let app: AXUIElement
    let item: AXUIElement
    /// It was already open (the user opened it): leave it as it was.
    let wasOpen: Bool

    static func open() -> WiFiMenu? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first?.processIdentifier
        else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        guard let bar: AXUIElement = app.attribute("AXExtrasMenuBar"),
              let items: [AXUIElement] = bar.attribute(kAXChildrenAttribute),
              let item = items.first(where: { ($0.attribute(kAXDescriptionAttribute) as String?)?.hasPrefix("Wi") == true })
        else { return nil }
        let wasOpen = !(app.windows.isEmpty)
        if !wasOpen {
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return nil }
        }
        return WiFiMenu(app: app, item: item, wasOpen: wasOpen)
    }

    func close() {
        guard !wasOpen, !app.windows.isEmpty else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    /// The list fills in over a second or two (Instant Hotspot devices show up last).
    func waitForEntry(id: String, timeout: TimeInterval) -> Entry? {
        waitFor(timeout: timeout) { $0.id == id }
    }

    func waitFor(timeout: TimeInterval, _ match: (Entry) -> Bool) -> Entry? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let entry = entries().first(where: match) { return entry }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    func entries() -> [Entry] {
        var found: [Entry] = []
        var budget = 3000
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 16, budget > 0 else { return }
            budget -= 1
            if let id: String = element.attribute("AXIdentifier"), id.hasPrefix("wifi-network-") {
                let value: NSNumber? = element.attribute(kAXValueAttribute)
                found.append(Entry(element: element, id: id, isChecked: value?.intValue == 1))
                return
            }
            for child in (element.attribute(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        for window in app.windows { walk(window, depth: 0) }
        return found
    }
}

private extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var windows: [AXUIElement] { attribute(kAXWindowsAttribute) ?? [] }
}
