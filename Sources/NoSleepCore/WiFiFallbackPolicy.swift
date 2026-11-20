import Foundation

/// What the internet looks like right now.
public enum InternetState: Sendable, Equatable {
    case online
    case offline
    /// Associated to a network that answers with its own page (hotel/café login). The user is probably
    /// signing in, so the fallback leaves them there.
    case captivePortal
}

/// Decides when the Wi‑Fi fallback should try to join the backup network. Pure: the app feeds it
/// observations and reports attempt results; it never touches the system.
///
/// Offline for `offlineDelay` → cycle 1. A failed cycle waits `retryDelays[n]` before the next one,
/// up to `maxCycles`; then it gives up until the internet comes back, the network changes, or the
/// feature is switched off.
public struct WiFiFallbackPolicy: Sendable {
    public static let offlineDelay: TimeInterval = 30
    public static let retryDelays: [TimeInterval] = [60, 180]
    public static let maxCycles = 3

    public enum Phase: Equatable, Sendable {
        case idle
        case attempting(cycle: Int)
        case waiting(cycle: Int, until: Date)
        case gaveUp
    }

    public private(set) var phase: Phase = .idle
    private var offline = SustainedCondition(limit: WiFiFallbackPolicy.offlineDelay)
    private var lastNetwork: String?
    private var networkAtGiveUp: String?

    public init() {}

    /// Returns the cycle number (1-based) to start now, or nil.
    public mutating func observe(
        enabled: Bool, configured: Bool, wifiPowered: Bool,
        internet: InternetState, network: String?, now: Date
    ) -> Int? {
        defer { lastNetwork = network }
        guard enabled, configured, wifiPowered else {
            reset()
            return nil
        }
        if internet != .offline {
            // Back online (or on a login page): nothing to rescue. A running attempt reports itself.
            if case .attempting = phase { return nil }
            phase = .idle
            offline.reset()
            return nil
        }
        switch phase {
        case .attempting:
            return nil
        case .waiting(let cycle, let until):
            guard now >= until else { return nil }
            phase = .attempting(cycle: cycle + 1)
            return cycle + 1
        case .gaveUp:
            guard network != networkAtGiveUp else { return nil }
            phase = .idle
            offline.reset()
            fallthrough
        case .idle:
            guard offline.observe(true, now: now) else { return nil }
            phase = .attempting(cycle: 1)
            return 1
        }
    }

    public mutating func attemptFinished(success: Bool, now: Date) {
        guard case .attempting(let cycle) = phase else { return } // switched off meanwhile
        offline.reset()
        if success {
            phase = .idle
        } else if cycle >= Self.maxCycles {
            phase = .gaveUp
            networkAtGiveUp = lastNetwork
        } else {
            phase = .waiting(cycle: cycle, until: now.addingTimeInterval(Self.retryDelays[cycle - 1]))
        }
    }

    public mutating func reset() {
        phase = .idle
        offline.reset()
        networkAtGiveUp = nil
    }
}
