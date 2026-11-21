import Foundation
import NoSleepCore
import Observation

/// Wi‑Fi fallback: when the internet drops, join a backup network the Mac already knows (typically an
/// iPhone hotspot). First the public way (`networksetup`), then by pressing it in the Wi‑Fi menu, which
/// is what wakes a locked iPhone (Instant Hotspot). `WiFiFallbackPolicy` decides when; this runs it.
///
/// It doesn't keep the Mac awake by itself: it only acts while something else does (or it's in use).
@MainActor
@Observable
final class WiFiFallback {
    enum Status: Equatable {
        case off
        case needsNetwork
        case ready
        case connecting
        case connected(at: Date)
        case retrying(at: Date)
        case gaveUp
    }

    private enum Keys {
        static let enabled = "wifiFallbackEnabled"
        static let ssid = "wifiFallbackSSID"
    }

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            cancelAttempt()
            onChange?()
        }
    }

    /// The backup network.
    var ssid: String? {
        didSet {
            defaults.set(ssid, forKey: Keys.ssid)
            cancelAttempt()
            onChange?()
        }
    }

    private(set) var knownNetworks: [String] = []
    private(set) var status: Status = .off
    private(set) var accessibilityTrusted = InstantHotspot.isTrusted
    private(set) var isTesting = false
    private(set) var testResult: String?

    /// Called when the settings change (SleepController re-evaluates probing).
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var policy = WiFiFallbackPolicy()
    /// Bumped on every start/cancel so a late result from a stale attempt is ignored.
    private var generation = 0
    private var connectedAt: Date?
    private var lastInternet: InternetState = .online
    // Sampled off the main thread while offline (networksetup blocks).
    private var wifiPowered = true
    private var currentNetwork: String?
    private var sampling = false

    init() {
        defaults.register(defaults: [Keys.enabled: false])
        enabled = defaults.bool(forKey: Keys.enabled)
        ssid = defaults.string(forKey: Keys.ssid)
        updateStatus()
    }

    func refreshKnownNetworks() {
        accessibilityTrusted = InstantHotspot.isTrusted
        Task.detached {
            let networks = WiFi.knownNetworks()
            await MainActor.run { self.knownNetworks = networks }
        }
    }

    func requestAccessibility() {
        InstantHotspot.requestTrust()
    }

    /// Fed by SleepController on every refresh and connectivity change.
    func tick(internet: InternetState) {
        lastInternet = internet
        accessibilityTrusted = InstantHotspot.isTrusted
        if internet == .offline, enabled { sample() }
        let cycle = policy.observe(
            enabled: enabled, configured: ssid != nil, wifiPowered: wifiPowered,
            internet: internet, network: currentNetwork, now: Date()
        )
        if let cycle, let ssid { start(cycle: cycle, ssid: ssid) }
        updateStatus()
    }

    /// Runs one cycle now, internet or not, and reports whether the Mac ended up on the backup
    /// network with internet. Leaves it there.
    func testNow() {
        guard let ssid, !isTesting else { return }
        isTesting = true
        testResult = String(localized: "Joining “\(ssid)”…")
        Task.detached {
            _ = await Self.runCycle(ssid: ssid)
            // The cycle stops as soon as there's internet, which during a test may still be the old
            // network: wait for the switch itself.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, WiFi.currentNetwork() != ssid {
                try? await Task.sleep(for: .seconds(2))
            }
            let onBackup = (WiFi.currentNetwork() ?? InstantHotspot.connectedNetwork()) == ssid
            let online = await Self.waitForInternet(seconds: onBackup ? 20 : 0)
            await MainActor.run {
                self.isTesting = false
                self.testResult = switch (onBackup, online) {
                case (true, true): String(localized: "Works: joined “\(ssid)” and the internet is up.")
                case (true, false): String(localized: "Joined “\(ssid)”, but it has no internet.")
                default: String(localized: "Couldn't join “\(ssid)”. Check the tips below.")
                }
            }
        }
    }

    // MARK: Private

    private func start(cycle: Int, ssid: String) {
        generation += 1
        let current = generation
        if cycle == 1 { connectedAt = nil }
        Task.detached {
            let success = await Self.runCycle(ssid: ssid)
            await MainActor.run { self.finish(generation: current, success: success) }
        }
    }

    private func finish(generation finished: Int, success: Bool) {
        guard finished == generation else { return }
        policy.attemptFinished(success: success, now: Date())
        if success { connectedAt = Date() }
        updateStatus()
    }

    private func cancelAttempt() {
        generation += 1
        policy.reset()
        connectedAt = nil
        updateStatus()
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        Task.detached {
            let powered = WiFi.isPoweredOn()
            let network = WiFi.currentNetwork()
            await MainActor.run {
                self.sampling = false
                self.wifiPowered = powered
                self.currentNetwork = network
            }
        }
    }

    private func updateStatus() {
        guard enabled else { status = .off; return }
        guard ssid != nil else { status = .needsNetwork; return }
        switch policy.phase {
        case .attempting: status = .connecting
        case .waiting(_, let until): status = .retrying(at: until)
        case .gaveUp: status = .gaveUp
        case .idle:
            if let connectedAt, Date().timeIntervalSince(connectedAt) < 3600, lastInternet == .online {
                status = .connected(at: connectedAt)
            } else {
                status = .ready
            }
        }
    }

    /// One cycle; true when the internet is back (on any network).
    nonisolated private static func runCycle(ssid: String) async -> Bool {
        // 1. The public way: works while the network is broadcasting.
        if WiFi.join(ssid) || WiFi.currentNetwork() == ssid {
            if await waitForInternet(seconds: 20) { return true }
        }
        // 2. Press it in the Wi‑Fi menu (Instant Hotspot for an iPhone).
        switch InstantHotspot.press(ssid) {
        case .pressed:
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if WiFi.currentNetwork() == ssid { break }
                if await Connectivity.probeOnce() == .online { return true }
                try? await Task.sleep(for: .seconds(2))
            }
            return await waitForInternet(seconds: 20)
        case .alreadyConnected:
            return await waitForInternet(seconds: 20)
        case .notFound, .menuUnavailable, .notTrusted:
            return await Connectivity.probeOnce() == .online
        }
    }

    nonisolated private static func waitForInternet(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await Connectivity.probeOnce() == .online { return true }
            try? await Task.sleep(for: .seconds(3))
        } while Date() < deadline
        return false
    }

    // MARK: Debug

    /// `NOSLEEP_WIFI_DEBUG=<ssid> NoSleep`: prints what the fallback sees, presses a network that doesn't
    /// exist (the menu opens and closes) and, with `NOSLEEP_WIFI_DEBUG_PRESS=1`, presses `<ssid>` for real;
    /// `NOSLEEP_WIFI_DEBUG_CYCLE=1` runs a whole fallback cycle to `<ssid>`.
    static func runDebugIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let ssid = env["NOSLEEP_WIFI_DEBUG"] else { return false }
        print("interface:", WiFi.interface() ?? "nil")
        print("powered:", WiFi.isPoweredOn())
        print("known:", WiFi.knownNetworks())
        print("current (networksetup):", WiFi.currentNetwork() ?? "nil")
        print("accessibility:", InstantHotspot.isTrusted)
        print("current (menu):", InstantHotspot.connectedNetwork() ?? "nil")
        Thread.sleep(forTimeInterval: 1)
        print("press(nonexistent):", InstantHotspot.press("nosleep-no-such-network"))
        if env["NOSLEEP_WIFI_DEBUG_CYCLE"] == "1" {
            let started = Date()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let ok = await runCycle(ssid: ssid)
                print("cycle(\(ssid)):", ok, "in", Int(Date().timeIntervalSince(started)), "s; now on", WiFi.currentNetwork() ?? "?")
                done.signal()
            }
            done.wait()
        } else if env["NOSLEEP_WIFI_DEBUG_PRESS"] == "1" {
            Thread.sleep(forTimeInterval: 1)
            print("press(\(ssid)):", InstantHotspot.press(ssid))
        }
        return true
    }
}
