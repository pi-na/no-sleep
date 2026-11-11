import Foundation
import Network
import Observation

/// Is there *real* internet? A network route (NWPathMonitor) isn't enough — Wi-Fi can be up while the
/// ISP is down or a captive portal is in the way — so while it matters we also probe Apple's
/// captive-portal endpoint over HTTPS.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true
    var onChange: (() -> Void)?
    /// Snapshot/debug only.
    var override: Bool? { didSet { recompute() } }

    private static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let probeInterval: TimeInterval = 30

    private let monitor = NWPathMonitor()
    private var pathSatisfied = true
    private var probeOK = true
    private var probing = false
    private var probeTimer: Timer?
    private var probeInFlight = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

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
            probeOK = true
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
            probeOK = false
            recompute()
            return
        }
        probeInFlight = true
        var request = URLRequest(url: Self.probeURL)
        request.setValue("NoSleep", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
                && data.map { String(decoding: $0, as: UTF8.self).contains("Success") } == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.probeInFlight = false
                // Ignore late results after probing was switched off.
                if self.probing { self.probeOK = ok }
                self.recompute()
            }
        }.resume()
    }

    private func recompute() {
        let online = override ?? (pathSatisfied && probeOK)
        guard online != isOnline else { return }
        isOnline = online
        onChange?()
    }
}
