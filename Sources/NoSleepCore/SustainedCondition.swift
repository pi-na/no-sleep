import Foundation

/// Fires once a condition has held continuously for `limit`.
/// Any observation where the condition is false restarts the count.
public struct SustainedCondition: Equatable, Sendable {
    public var limit: TimeInterval
    public private(set) var since: Date?

    public init(limit: TimeInterval, since: Date? = nil) {
        self.limit = limit
        self.since = since
    }

    /// Returns `true` exactly when the condition has held for `limit` (the count then restarts).
    public mutating func observe(_ condition: Bool, now: Date = Date()) -> Bool {
        guard condition else {
            since = nil
            return false
        }
        let start = since ?? now
        if now.timeIntervalSince(start) >= limit {
            since = nil
            return true
        }
        since = start
        return false
    }

    public mutating func reset() {
        since = nil
    }

    public func remaining(now: Date = Date()) -> TimeInterval? {
        since.map { max(0, limit - now.timeIntervalSince($0)) }
    }
}

public extension Lease {
    /// Leases created by LLM agent hooks (Claude Code, Codex — including T3 Code threads).
    var isAgent: Bool { AgentKind(rawValue: source) != nil }
}
