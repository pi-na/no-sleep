import Foundation

/// How hot macOS says the machine is (mirrors `ProcessInfo.ThermalState`).
public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    /// `serious` and `critical` both mean macOS is throttling to cool down.
    public var isHot: Bool { self >= .serious }

    public var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Trips when the Mac has been hot *while being kept awake* for `limit` without interruption.
/// Any reading that is not hot (or a moment where No Sleep isn't active) restarts the count.
public struct ThermalFailsafe: Equatable, Sendable {
    public static let defaultLimit: TimeInterval = 20 * 60

    public var limit: TimeInterval
    public private(set) var hotSince: Date?

    public init(limit: TimeInterval = ThermalFailsafe.defaultLimit, hotSince: Date? = nil) {
        self.limit = limit
        self.hotSince = hotSince
    }

    /// Feed a reading. Returns `true` exactly when the failsafe trips (the count then restarts).
    public mutating func observe(level: ThermalLevel, isActive: Bool, now: Date = Date()) -> Bool {
        guard level.isHot, isActive else {
            hotSince = nil
            return false
        }
        let start = hotSince ?? now
        if now.timeIntervalSince(start) >= limit {
            hotSince = nil
            return true
        }
        hotSince = start
        return false
    }

    public mutating func reset() {
        hotSince = nil
    }

    /// Time left before tripping, while counting.
    public func remaining(now: Date = Date()) -> TimeInterval? {
        hotSince.map { max(0, limit - now.timeIntervalSince($0)) }
    }
}
