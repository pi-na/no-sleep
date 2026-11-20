import Foundation
import Network
import NoSleepCore
import Observation

/// Is there *real* internet? A network route (NWPathMonitor) isn't enough — Wi-Fi can be up while the
/// ISP is down or a captive portal is in the way — so while it matters we also probe Apple's
/// captive-portal endpoint over HTTPS.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true
    /// Finer-grained than `isOnline`: tells a captive portal apart (used by the Wi‑Fi fallback).
    private(set) var internet: InternetState = .online
    var onChange: (() -> Void)?
    /// Snapshot/debug only.
    var override: Bool? { didSet { recompute() } }

    nonisolated private static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let probeInterval: TimeInterval = 30

    private let monitor = NWPathMonitor()
    private var pathSatisfied = true
    private var probeResult: InternetState = .online
    private var probing = false
    private var probeTimer: Timer?
    private var probeInFlight = false
    private let session = Connectivity.makeSession()

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    nonisolated private static let sharedSession = makeSession()

    /// One probe, outside the observable state (the Wi‑Fi fallback checks after each step).
    nonisolated static func probeOnce() async -> InternetState {
        await withCheckedContinuation { continuation in
            sharedSession.dataTask(with: probeRequest()) { data, response, error in
                continuation.resume(returning: classify(data: data, response: response, error: error))
            }.resume()
        }
    }

    nonisolated private static func probeRequest() -> URLRequest {
        var request = URLRequest(url: probeURL)
        request.setValue("NoSleep", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Apple's page says "Success"; any other HTTP answer is someone else's page (captive portal);
    /// no answer at all is offline.
    nonisolated private static func classify(data: Data?, response: URLResponse?, error: Error?) -> InternetState {
        guard error == nil, let http = response as? HTTPURLResponse else { return .offline }
        if http.statusCode == 200, let data, String(decoding: data, as: UTF8.self).contains("Success") {
            return .online
        }
        return .captivePortal
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            guard let self else { return }
            Task { @MainActor in self.pathChanged(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.tomaspinausig.nosleep.network"))
    }

    /// Probe only while someone cares (agents holding the Mac awake), to stay off the network otherwise.
    func setProbing(_ enabled: Bool) {
        guard enabled != probing else { return }
        probing = enabled
        probeTimer?.invalidate()
        probeTimer = nil
        if enabled {
            probe()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.probe() }
            }
            timer.tolerance = 5
            probeTimer = timer
        } else {
            probeResult = .online
            recompute()
        }
    }

    private func pathChanged(_ satisfied: Bool) {
        pathSatisfied = satisfied
        if satisfied, probing { probe() }
        recompute()
    }

    private func probe() {
        guard !probeInFlight else { return }
        guard pathSatisfied else {
            probeResult = .offline
            recompute()
            return
        }
        probeInFlight = true
        session.dataTask(with: Self.probeRequest()) { data, response, error in
            let result = Self.classify(data: data, response: response, error: error)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.probeInFlight = false
                // Ignore late results after probing was switched off.
                if self.probing { self.probeResult = result }
                self.recompute()
            }
        }.resume()
    }

    private func recompute() {
        let state: InternetState
        if let override {
            state = override ? .online : .offline
        } else {
            state = pathSatisfied ? probeResult : .offline
        }
        guard state != internet else { return }
        internet = state
        isOnline = state == .online
        onChange?()
    }
}
