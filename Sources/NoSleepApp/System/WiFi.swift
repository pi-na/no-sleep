import Foundation

/// Wi‑Fi through `networksetup` (no permissions needed). Every call blocks: run them off the main thread.
enum WiFi {
    /// BSD name of the Wi‑Fi port ("en0"), from `-listallhardwareports`.
    static func interface() -> String? {
        guard let out = run(["-listallhardwareports"]) else { return nil }
        var inWiFi = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") {
                inWiFi = line.contains("Wi-Fi") || line.contains("AirPort")
            } else if inWiFi, line.hasPrefix("Device:") {
                return line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Networks the Mac remembers, in its preferred order.
    static func knownNetworks() -> [String] {
        guard let interface = interface(), let out = run(["-listpreferredwirelessnetworks", interface]) else { return [] }
        return out.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func isPoweredOn() -> Bool {
        guard let interface = interface(), let out = run(["-getairportpower", interface]) else { return true }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("On")
    }

    /// The network the Mac is on, or nil when not associated or when macOS hides it (15+ without
    /// Location permission, which we don't ask for).
    static func currentNetwork() -> String? {
        guard let interface = interface(), let out = run(["-getairportnetwork", interface]) else { return nil }
        let prefix = "Current Wi-Fi Network: "
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let name = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Joins with the password from the keychain. Only works while the network is broadcasting
    /// (a locked iPhone usually isn't: see `InstantHotspot`).
    @discardableResult
    static func join(_ ssid: String) -> Bool {
        guard let interface = interface(), let out = run(["-setairportnetwork", interface, ssid]) else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs so a full pipe can't block it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
